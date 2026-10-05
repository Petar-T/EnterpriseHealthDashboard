/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : tests/verify-staging-schema.sql
  Run in : the CENTRAL repository database
  Run    : AFTER the first successful collection job, BEFORE trusting anything

  WHY THIS FILE EXISTS
  --------------------
  This system has exactly one assumption it cannot verify at build time.

  Elastic Jobs does not write into tables you define. When a job step has
  @output_table_name set, the Job Agent CREATES that table itself on first run.

  IT ADDS EXACTLY ONE COLUMN OF ITS OWN: internal_execution_id uniqueidentifier.
  That is all Microsoft documents, and it is all the agent actually does:

      "If you want to manually create the table ahead of time, then it needs to
       have the following properties: Columns with the correct name and data
       types for the result set. Additional column for internal_execution_id
       with the data type of uniqueidentifier. A nonclustered index named
       IX_<TableName>_Internal_Execution_ID on the internal_execution_id column."
      - learn.microsoft.com/azure/azure-sql/database/elastic-jobs-tsql-create-manage

  It does NOT add target_server_name or target_database_name. Those two columns
  exist on the jobs.job_executions CATALOG VIEW, which is a different thing
  entirely - a very common and costly confusion.

  THEREFORE: every collection query emits its own identity, exactly as the
  Microsoft sample does ("SELECT DB_NAME() DatabaseName, ... FROM sys.dm_...").
  Each @command in 21/22/23-jobs-*.sql starts with:

        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),

  evaluated INSIDE the target database, so it is always correct. The names are
  still read through settings so you can rename them without touching the 65
  call sites in core.usp_Normalize:

        cfg.Setting 'Staging.ServerColumn'    default ServerName
        cfg.Setting 'Staging.DatabaseColumn'  default DatabaseName

  If a collection query is ever edited and loses those two columns,
  normalization will skip that feed - silently, by design, because
  core.fn_StagingReady checks before it touches anything. The dashboard would
  then show a fleet of databases with no data and you would have no idea why.

  This script tells you, in one run, whether that assumption holds.

  WHAT IT CHECKS
  --------------
     1. Do the stg.* tables exist at all?          (job has never run if not)
     2. What columns did the agent actually add?   (the real answer, not a guess)
     3. Do the configured setting values match?    (the thing that breaks silently)
     4. Does every feed pass fn_StagingReady?      (the guard normalize uses)
     5. Are rows actually landing?                 (permissions vs plumbing)

  It is READ-ONLY apart from the optional auto-fix at the very bottom, which is
  commented out and must be uncommented deliberately.
==============================================================================*/
/* Required SET options. sqlcmd.exe defaults QUOTED_IDENTIFIER to OFF, which makes
   CREATE INDEX fail on any filtered index and bakes the wrong options into views
   and procedures. SSMS and Invoke-Sqlcmd default it ON, so this only bites when
   deploying the documented way - with sqlcmd. Set it explicitly and the script
   behaves identically from every client. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

PRINT '';
PRINT '================================================================';
PRINT ' EHD STAGING SCHEMA VERIFICATION';
PRINT '================================================================';
PRINT '';
GO

/*------------------------------------------------------------------------------
  CHECK 1 - do the staging tables exist?

  Every feed that core.usp_Normalize knows about is listed here. A missing
  table means that job step has never completed successfully even once.
------------------------------------------------------------------------------*/
PRINT '--- CHECK 1: staging tables ---------------------------------';

DECLARE @expected TABLE (FeedName sysname PRIMARY KEY, Tier varchar(20), JobFile varchar(40));
INSERT @expected VALUES
    ('ResourceUsage',      'Frequent', '21-jobs-frequent.sql'),
    ('ActiveRequest',      'Frequent', '21-jobs-frequent.sql'),
    ('BlockingChain',      'Frequent', '21-jobs-frequent.sql'),
    ('SessionActivity',    'Frequent', '21-jobs-frequent.sql'),
    ('WaitStats',          'Frequent', '21-jobs-frequent.sql'),
    ('QueryStats',         'Standard', '22-jobs-standard.sql'),
    ('QueryStoreTopQuery', 'Standard', '22-jobs-standard.sql'),
    ('Space',              'Standard', '22-jobs-standard.sql'),
    ('IoFileStats',        'Standard', '22-jobs-standard.sql'),
    ('XeErrors',           'Standard', '22-jobs-standard.sql'),
    ('XeBlocking',         'Standard', '22-jobs-standard.sql'),
    ('XeSessionHealth',    'Standard', '22-jobs-standard.sql'),
    ('IndexUsage',         'Daily',    '23-jobs-daily.sql'),
    ('MissingIndex',       'Daily',    '23-jobs-daily.sql'),
    ('IndexFragmentation', 'Daily',    '23-jobs-daily.sql'),
    ('TableSpace',         'Daily',    '23-jobs-daily.sql'),
    ('SecurityPrincipal',  'Daily',    '23-jobs-daily.sql'),
    ('SecurityPermission', 'Daily',    '23-jobs-daily.sql');

SELECT  Feed      = e.FeedName,
        e.Tier,
        StagingTable = 'stg.' + e.FeedName,
        Exists_    = CASE WHEN OBJECT_ID('stg.' + e.FeedName) IS NOT NULL THEN 'yes' ELSE 'NO' END,
        Verdict   = CASE WHEN OBJECT_ID('stg.' + e.FeedName) IS NOT NULL
                         THEN 'ok'
                         ELSE 'MISSING - the job step in ' + e.JobFile
                              + ' has never completed successfully' END
FROM    @expected AS e
ORDER BY CASE WHEN OBJECT_ID('stg.' + e.FeedName) IS NULL THEN 0 ELSE 1 END,
         e.Tier, e.FeedName;
GO


/*------------------------------------------------------------------------------
  CHECK 2 - what the staging table actually looks like.

  This is the ground truth. Everything else in this file is comparing against
  what you see here.

  Expected on any current agent:
      ... your SELECT list, starting with ServerName and DatabaseName ...
      internal_execution_id  uniqueidentifier   <-- the agent's only addition

  If you see target_server_name / target_database_name here, the table was
  created by something other than the documented agent behaviour - investigate
  before trusting it.
------------------------------------------------------------------------------*/
PRINT '';
PRINT '--- CHECK 2: staging table shape -----------------------------';

DECLARE @sample sysname = (
    SELECT TOP (1) t.name
    FROM   sys.tables  AS t
    JOIN   sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE  s.name = 'stg'
    ORDER BY t.name);

IF @sample IS NULL
    PRINT '  !! No stg.* tables exist at all. No collection job has ever run.';
ELSE
BEGIN
    PRINT '  Using stg.' + @sample + ' as the reference table.';
    PRINT '';

    SELECT  Ordinal   = c.column_id,
            ColumnName= c.name,
            DataType  = ty.name,
            Length    = CASE WHEN ty.name LIKE '%char%' OR ty.name LIKE '%binary%'
                             THEN CONVERT(varchar(20), c.max_length) ELSE '' END,
            Origin    = CASE WHEN c.name = 'internal_execution_id'
                             THEN '<-- added by the Job Agent'
                             WHEN c.name IN ('ServerName','DatabaseName')
                             THEN '<-- identity, emitted by the collection query'
                             ELSE 'from the collection query' END
    FROM    sys.columns AS c
    JOIN    sys.types   AS ty ON ty.user_type_id = c.user_type_id
    WHERE   c.object_id = OBJECT_ID('stg.' + @sample)
    ORDER BY c.column_id;
END
GO


/*------------------------------------------------------------------------------
  CHECK 3 - do the configured column names actually exist?

  THIS IS THE CHECK THAT MATTERS. If it fails, normalization silently
  processes nothing and the whole system looks broken for no visible reason.
------------------------------------------------------------------------------*/
PRINT '';
PRINT '--- CHECK 3: configured column names -------------------------';

DECLARE @srvCol sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey = 'Staging.ServerColumn'),   N'ServerName');
DECLARE @dbCol  sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey = 'Staging.DatabaseColumn'), N'DatabaseName');
DECLARE @ref    sysname = (SELECT TOP (1) t.name FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
                           WHERE s.name = 'stg' ORDER BY t.name);

IF @ref IS NULL
    PRINT '  (skipped - no staging tables yet)';
ELSE
BEGIN
    DECLARE @srvOk bit = CASE WHEN COL_LENGTH('stg.' + @ref, @srvCol) IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @dbOk  bit = CASE WHEN COL_LENGTH('stg.' + @ref, @dbCol)  IS NOT NULL THEN 1 ELSE 0 END;

    SELECT  Setting   = 'Staging.ServerColumn',
            Configured= @srvCol,
            FoundInStaging = CASE WHEN @srvOk = 1 THEN 'yes' ELSE 'NO' END,
            Verdict   = CASE WHEN @srvOk = 1 THEN 'ok'
                             ELSE 'MISMATCH - normalize will skip every feed' END
    UNION ALL
    SELECT  'Staging.DatabaseColumn', @dbCol,
            CASE WHEN @dbOk = 1 THEN 'yes' ELSE 'NO' END,
            CASE WHEN @dbOk = 1 THEN 'ok'
                 ELSE 'MISMATCH - normalize will skip every feed' END;

    IF @srvOk = 0 OR @dbOk = 0
    BEGIN
        PRINT '';
        PRINT '  ************************************************************';
        PRINT '  ** COLUMN NAME MISMATCH                                   **';
        PRINT '  ************************************************************';
        PRINT '  A collection query is not emitting the identity columns, or';
        PRINT '  the settings point at names that do not exist. Nothing will';
        PRINT '  ever normalize.';
        PRINT '';
        PRINT '  Every @command in 21/22/23-jobs-*.sql must start its result';
        PRINT '  set with:';
        PRINT '      ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),';
        PRINT '      DatabaseName = DB_NAME(),';
        PRINT '';
        PRINT '  Elastic Jobs does NOT supply these - it only adds';
        PRINT '  internal_execution_id. Compare CHECK 2 above, fix the query,';
        PRINT '  DROP the affected stg.* table so the agent recreates it with';
        PRINT '  the new shape, then re-run the job.';
        PRINT '';
        PRINT '  If you deliberately renamed the columns, repoint the settings:';
        PRINT '    UPDATE cfg.Setting SET SettingValue = N''<actual server column>''';
        PRINT '     WHERE SettingKey = ''Staging.ServerColumn'';';
        PRINT '    UPDATE cfg.Setting SET SettingValue = N''<actual database column>''';
        PRINT '     WHERE SettingKey = ''Staging.DatabaseColumn'';';
        PRINT '';
        PRINT '  Then:  EXEC core.usp_Normalize;';
        PRINT '  ************************************************************';
    END
    ELSE
        PRINT '  Both configured column names exist. Normalization can proceed.';
END
GO


/*------------------------------------------------------------------------------
  CHECK 4 - run the real guard.

  core.fn_StagingReady is what core.usp_Normalize consults before every feed.
  Calling it here reproduces the exact decision normalize will make, including
  the per-feed column requirements, rather than approximating it.
------------------------------------------------------------------------------*/
PRINT '';
PRINT '--- CHECK 4: fn_StagingReady per feed ------------------------';

DECLARE @srv sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey='Staging.ServerColumn'),   N'ServerName');
DECLARE @db  sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey='Staging.DatabaseColumn'), N'DatabaseName');

/* the required-column list per feed mirrors core.usp_Normalize exactly */
DECLARE @feeds TABLE (FeedName sysname PRIMARY KEY, RequiredCols nvarchar(400));
INSERT @feeds VALUES
 ('ResourceUsage',      @srv + ',' + @db + ',EndTimeUtc'),
 ('ActiveRequest',      @srv + ',' + @db + ',SnapshotUtc'),
 ('BlockingChain',      @srv + ',' + @db + ',SnapshotUtc'),
 ('SessionActivity',    @srv + ',' + @db + ',SnapshotUtc'),
 ('WaitStats',          @srv + ',' + @db + ',SnapshotUtc,WaitType'),
 ('QueryStats',         @srv + ',' + @db + ',SnapshotUtc,QueryHash'),
 ('QueryStoreTopQuery', @srv + ',' + @db + ',SnapshotUtc'),
 ('Space',              @srv + ',' + @db + ',SnapshotUtc'),
 ('IoFileStats',        @srv + ',' + @db + ',SnapshotUtc,FileId'),
 ('XeErrors',           @srv + ',' + @db + ',EventTimeUtc'),
 ('XeBlocking',         @srv + ',' + @db + ',EventTimeUtc'),
 ('XeSessionHealth',    @srv + ',' + @db + ',SnapshotUtc,SessionName'),
 ('IndexUsage',         @srv + ',' + @db + ',SnapshotDate,SchemaName,TableName,IndexName'),
 ('MissingIndex',       @srv + ',' + @db + ',SnapshotDate'),
 ('IndexFragmentation', @srv + ',' + @db + ',SnapshotDate,SchemaName,TableName,IndexName'),
 ('TableSpace',         @srv + ',' + @db + ',SnapshotDate,SchemaName,TableName'),
 ('SecurityPrincipal',  @srv + ',' + @db + ',SnapshotDate,PrincipalName'),
 ('SecurityPermission', @srv + ',' + @db + ',SnapshotDate,GranteeName');

SELECT  Feed      = f.FeedName,
        TableThere= CASE WHEN OBJECT_ID('stg.' + f.FeedName) IS NOT NULL THEN 'yes' ELSE 'no' END,
        Ready     = CASE WHEN core.fn_StagingReady(f.FeedName, f.RequiredCols) = 1 THEN 'YES' ELSE 'no' END,
        Verdict   = CASE
            WHEN core.fn_StagingReady(f.FeedName, f.RequiredCols) = 1 THEN 'will normalize'
            WHEN OBJECT_ID('stg.' + f.FeedName) IS NULL THEN 'job step has never run'
            ELSE 'TABLE EXISTS BUT A REQUIRED COLUMN IS MISSING - compare against CHECK 2' END,
        RequiredColumns = f.RequiredCols
FROM    @feeds AS f
ORDER BY CASE WHEN core.fn_StagingReady(f.FeedName, f.RequiredCols) = 1 THEN 1 ELSE 0 END, f.FeedName;
GO


/*------------------------------------------------------------------------------
  CHECK 5 - are rows actually landing?

  A table that exists with the right columns but zero rows means the job is
  connecting and the shape is right, but the collection query returned nothing.
  Usually a permissions problem on the target, not a plumbing problem here.
------------------------------------------------------------------------------*/
PRINT '';
PRINT '--- CHECK 5: row counts in staging ---------------------------';

DECLARE @counts TABLE (TableName sysname, Rows_ bigint);
DECLARE @t sysname, @q nvarchar(max);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'stg' ORDER BY t.name;
OPEN cur; FETCH NEXT FROM cur INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @q = N'SELECT @n = COUNT_BIG(*) FROM stg.' + QUOTENAME(@t) + N';';
    DECLARE @n bigint;
    EXEC sys.sp_executesql @q, N'@n bigint OUTPUT', @n OUTPUT;
    INSERT @counts VALUES (@t, @n);
    FETCH NEXT FROM cur INTO @t;
END
CLOSE cur; DEALLOCATE cur;

SELECT  StagingTable = 'stg.' + TableName,
        Rows_,
        Verdict = CASE WHEN Rows_ > 0 THEN 'data is landing'
                       ELSE 'EMPTY - the job ran but the query returned no rows. '
                          + 'Check the agent identity has VIEW DATABASE STATE on the target (see 10-target-permissions.sql).' END
FROM    @counts
ORDER BY Rows_ ASC, TableName;
GO


/*------------------------------------------------------------------------------
  SUMMARY - the one-line answer
------------------------------------------------------------------------------*/
PRINT '';
PRINT '--- SUMMARY --------------------------------------------------';

DECLARE @stgTables int = (SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='stg');
DECLARE @coreRows  bigint = (SELECT ISNULL(SUM(p.rows),0) FROM sys.partitions p
                             JOIN sys.tables t ON t.object_id=p.object_id
                             JOIN sys.schemas s ON s.schema_id=t.schema_id
                             WHERE s.name='core' AND p.index_id IN (0,1));
DECLARE @feedRows  int = (SELECT COUNT(*) FROM core.FeedArrival);
DECLARE @tgtCount  int = (SELECT COUNT(*) FROM cfg.Target WHERE IsEnabled=1);

SELECT  StagingTables    = @stgTables,
        RowsInCore       = @coreRows,
        FeedArrivalRows  = @feedRows,
        EnabledTargets   = @tgtCount,
        Verdict = CASE
            WHEN @stgTables = 0
                 THEN 'NOTHING HAS RUN. Start a collection job: EXEC jobs.sp_start_job ''EHD_Collect_Frequent'';'
            WHEN @coreRows = 0 AND @stgTables > 0
                 THEN 'COLLECTION WORKS, NORMALIZATION DOES NOT. Almost certainly the column-name mismatch in CHECK 3.'
            WHEN @feedRows = 0
                 THEN 'Rows are in core but FeedArrival is empty - usp_RecordArrival is not being called. Redeploy 02-normalize.sql.'
            WHEN @tgtCount = 0
                 THEN 'Pipeline is healthy but cfg.Target is empty - register targets or let EHD_Process_Daily auto-register them.'
            ELSE 'HEALTHY - staging, normalization and the target registry are all working.' END;

PRINT '';
PRINT '================================================================';
GO


/*==============================================================================
  OPTIONAL AUTO-FIX
  ------------------------------------------------------------------------------
  If CHECK 3 reported a mismatch, this block finds the correct column names by
  INSPECTION rather than by guessing, and updates cfg.Setting.

  It is commented out on purpose. Read the CHECK 2 output first and confirm the
  columns it picks are the ones you actually want - a heuristic that matches the
  wrong column is worse than a clear failure.
==============================================================================*/
/*
DECLARE @ref2 sysname = (SELECT TOP (1) t.name FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
                         WHERE s.name='stg' ORDER BY t.name);
DECLARE @foundSrv sysname, @foundDb sysname;

SELECT TOP (1) @foundSrv = c.name
FROM   sys.columns c WHERE c.object_id = OBJECT_ID('stg.' + @ref2)
  AND  (c.name LIKE '%server%name%' OR c.name LIKE '%server_name%')
ORDER BY c.column_id;

SELECT TOP (1) @foundDb = c.name
FROM   sys.columns c WHERE c.object_id = OBJECT_ID('stg.' + @ref2)
  AND  (c.name LIKE '%database%name%' OR c.name LIKE '%db_name%')
ORDER BY c.column_id;

SELECT DetectedServerColumn = @foundSrv, DetectedDatabaseColumn = @foundDb;

IF @foundSrv IS NOT NULL AND @foundDb IS NOT NULL
BEGIN
    UPDATE cfg.Setting SET SettingValue = @foundSrv, ModifiedUtc = SYSUTCDATETIME()
     WHERE SettingKey = 'Staging.ServerColumn';
    UPDATE cfg.Setting SET SettingValue = @foundDb,  ModifiedUtc = SYSUTCDATETIME()
     WHERE SettingKey = 'Staging.DatabaseColumn';
    PRINT 'Settings updated. Now run: EXEC core.usp_Normalize;';
END
ELSE
    PRINT 'Could not detect the columns automatically - set them by hand from the CHECK 2 output.';
*/
