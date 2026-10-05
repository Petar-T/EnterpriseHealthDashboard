/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 01-central/02-normalize.sql
  Run in : the CENTRAL repository database

  Moves landed rows from stg.* into core.*, de-duplicating as it goes.

  ------------------------------------------------------------------------------
  WHY THIS LAYER EXISTS AT ALL
  ------------------------------------------------------------------------------
  Elastic Jobs appends. It never updates, never de-duplicates, and re-runs after
  a retry produce the same rows again. Ring buffer harvests re-read the same
  events every 30 minutes until they age out. Left alone, stg.* would grow
  without bound and be full of duplicates.

  core.* is therefore the only thing the views and the dashboard ever read.

  ------------------------------------------------------------------------------
  DEFENSIVE BY DESIGN
  ------------------------------------------------------------------------------
  The agent creates the stg.* tables itself on first run. It adds exactly ONE
  column of its own - internal_execution_id uniqueidentifier - and nothing else.
  It does NOT supply the target server or database name; target_server_name and
  target_database_name belong to the jobs.job_executions CATALOG VIEW, which is
  a different object entirely.

  So each collection query emits its own identity, the way Microsoft's own
  sample does:
      ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
      DatabaseName = DB_NAME(),
  evaluated inside the target database, so it cannot be wrong.

  Every step here still defends itself:

      * checks the table exists at all               -> skip if not
      * checks the columns it needs exist            -> skip if not
      * reports what it skipped and why

  Run tests/verify-staging-schema.sql after the first collection to confirm the
  real shape. If you rename the identity columns, change the two settings rather
  than editing all 65 call sites below:
      Staging.ServerColumn    (default ServerName)
      Staging.DatabaseColumn  (default DatabaseName)
==============================================================================*/
/* Required SET options. sqlcmd.exe defaults QUOTED_IDENTIFIER to OFF, which makes
   CREATE INDEX fail on any filtered index and bakes the wrong options into views
   and procedures. SSMS and Invoke-Sqlcmd default it ON, so this only bites when
   deploying the documented way - with sqlcmd. Set it explicitly and the script
   behaves identically from every client. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

MERGE cfg.Setting AS tgt
USING (VALUES
    ('Staging.ServerColumn',   N'ServerName',   N'Identity column emitted by each collection query naming the source server'),
    ('Staging.DatabaseColumn', N'DatabaseName', N'Identity column emitted by each collection query naming the source database')
) AS src (SettingKey, SettingValue, Description)
   ON tgt.SettingKey = src.SettingKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (SettingKey, SettingValue, Description) VALUES (src.SettingKey, src.SettingValue, src.Description);
GO

/*------------------------------------------------------------------------------
  Guard: does a staging table exist with every column we are about to read?
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION core.fn_StagingReady (@Table sysname, @RequiredCsv nvarchar(max))
RETURNS bit
AS
BEGIN
    IF OBJECT_ID('stg.' + QUOTENAME(@Table)) IS NULL RETURN 0;

    DECLARE @missing int;
    SELECT @missing = COUNT(*)
    FROM   STRING_SPLIT(@RequiredCsv, ',') AS s
    WHERE  LTRIM(RTRIM(s.value)) <> ''
      AND  COL_LENGTH('stg.' + QUOTENAME(@Table), LTRIM(RTRIM(s.value))) IS NULL;

    RETURN CASE WHEN @missing = 0 THEN 1 ELSE 0 END;
END;
GO

/*------------------------------------------------------------------------------
  Record what arrived, from whom, and when - the basis of staleness detection.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE core.usp_RecordArrival
    @FeedName varchar(64),
    @Tier     varchar(20),
    @Table    sysname
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('stg.' + QUOTENAME(@Table)) IS NULL RETURN;

    DECLARE @srvCol sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey='Staging.ServerColumn'),   N'ServerName');
    DECLARE @dbCol  sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey='Staging.DatabaseColumn'), N'DatabaseName');
    IF COL_LENGTH('stg.' + QUOTENAME(@Table), @srvCol) IS NULL RETURN;

    /*--------------------------------------------------------------------------
      WHEN did this data arrive?

      There is NO agent-supplied timestamp to use. Elastic Jobs adds exactly one
      column to an output table - internal_execution_id - and nothing else. An
      earlier version of this procedure read MAX(last_modify_time), a column that
      does not exist; the MERGE threw "Invalid column name", the CATCH below
      swallowed it, and core.FeedArrival stayed permanently empty while Normalize
      cheerfully reported Success. Every database then showed NO DATA on the
      dashboard despite core.* being full.

      So use the feed's OWN timestamp, which the collection query emits. The
      column differs per feed, hence the probe rather than a parameter - that
      keeps all 18 call sites unchanged.
    --------------------------------------------------------------------------*/
    DECLARE @timeCol sysname = COALESCE(
        CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@Table), 'SnapshotUtc')  IS NOT NULL THEN N'SnapshotUtc'  END,
        CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@Table), 'EndTimeUtc')   IS NOT NULL THEN N'EndTimeUtc'   END,
        CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@Table), 'EventTimeUtc') IS NOT NULL THEN N'EventTimeUtc' END,
        CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@Table), 'SnapshotDate') IS NOT NULL THEN N'SnapshotDate' END);

    DECLARE @arrivalExpr nvarchar(300) =
        CASE WHEN @timeCol IS NULL
             THEN N'MAX(CONVERT(datetime2(3), SYSUTCDATETIME()))'   -- last resort: observation time
             ELSE N'MAX(CONVERT(datetime2(3), ' + QUOTENAME(@timeCol) + N'))' END;

    DECLARE @sql nvarchar(max) = N'
    MERGE core.FeedArrival AS t
    USING (SELECT ServerName = ' + QUOTENAME(@srvCol) + N',
                  DatabaseName = ' + QUOTENAME(@dbCol) + N',
                  LastArrival = ' + @arrivalExpr + N',
                  Rows = COUNT_BIG(*)
           FROM   stg.' + QUOTENAME(@Table) + N'
           GROUP BY ' + QUOTENAME(@srvCol) + N', ' + QUOTENAME(@dbCol) + N') AS s
       ON t.ServerName = s.ServerName AND t.DatabaseName = s.DatabaseName
      AND t.FeedName = @Feed
    WHEN MATCHED AND s.LastArrival > t.LastArrivalUtc THEN
        UPDATE SET LastArrivalUtc = s.LastArrival, LastRowCount = s.Rows
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ServerName, DatabaseName, FeedName, Tier, LastArrivalUtc, LastRowCount)
        VALUES (s.ServerName, s.DatabaseName, @Feed, @Tier, s.LastArrival, s.Rows);';

    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@Feed varchar(64), @Tier varchar(20)', @Feed = @FeedName, @Tier = @Tier;
    END TRY
    BEGIN CATCH
        /* Deliberately non-fatal - arrival tracking must never fail the whole
           normalize run. But it must be VISIBLE: a bare PRINT let this exact
           procedure fail silently for every feed, on every run, indefinitely.
           ProcessRun is where the operator already looks. */
        PRINT '  arrival tracking failed for ' + @Table + ': ' + ERROR_MESSAGE();
        INSERT INTO core.ProcessRun (StepName, Status, CompletedUtc, ErrorNumber, ErrorMessage)
        VALUES ('RecordArrival:' + @FeedName, 'Failed', SYSUTCDATETIME(),
                ERROR_NUMBER(), LEFT(ERROR_MESSAGE(), 2048));
    END CATCH;

    -- keep the target registry's LastSeen current, and auto-register newcomers
    DECLARE @reg nvarchar(max) = N'
    MERGE cfg.Target AS t
    USING (SELECT DISTINCT ServerName = ' + QUOTENAME(@srvCol) + N',
                           DatabaseName = ' + QUOTENAME(@dbCol) + N'
           FROM   stg.' + QUOTENAME(@Table) + N') AS s
       ON t.ServerName = s.ServerName AND t.DatabaseName = s.DatabaseName
    WHEN MATCHED THEN UPDATE SET LastSeenUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ServerName, DatabaseName, LastSeenUtc, Notes)
        VALUES (s.ServerName, s.DatabaseName, SYSUTCDATETIME(),
                N''auto-registered on first data arrival'');';
    BEGIN TRY EXEC sys.sp_executesql @reg; END TRY
    BEGIN CATCH PRINT '  target registration failed: ' + ERROR_MESSAGE(); END CATCH;
END;
GO


/*==============================================================================
  THE NORMALIZER
  One procedure, one pass, every feed. Each feed is independently wrapped so a
  single malformed table cannot stop the rest.
==============================================================================*/
CREATE OR ALTER PROCEDURE core.usp_Normalize
    @Debug bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE @RunId bigint, @rows bigint = 0, @total bigint = 0, @skipped int = 0;
    INSERT INTO core.ProcessRun (StepName, Status) VALUES ('Normalize', 'Running');
    SET @RunId = SCOPE_IDENTITY();

    DECLARE @srv sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey='Staging.ServerColumn'),   N'ServerName');
    DECLARE @db  sysname = ISNULL((SELECT SettingValue FROM cfg.Setting WHERE SettingKey='Staging.DatabaseColumn'), N'DatabaseName');
    DECLARE @S nvarchar(300) = QUOTENAME(@srv);
    DECLARE @D nvarchar(300) = QUOTENAME(@db);
    DECLARE @sql nvarchar(max);

    /*=========================================================== ResourceUsage */
    IF core.fn_StagingReady('ResourceUsage', @srv + ',' + @db + ',EndTimeUtc') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.ResourceUsage
                (ServerName, DatabaseName, EndTimeUtc, AvgCpuPct, AvgDataIoPct, AvgLogWritePct,
                 AvgMemoryPct, MaxWorkerPct, MaxSessionPct, XtpStoragePct, AvgInstanceCpuPct,
                 DtuLimit, CpuLimit)
            SELECT s.' + @S + N', s.' + @D + N', s.EndTimeUtc,
                   MAX(s.AvgCpuPct), MAX(s.AvgDataIoPct), MAX(s.AvgLogWritePct),
                   MAX(s.AvgMemoryPct), MAX(s.MaxWorkerPct), MAX(s.MaxSessionPct),
                   MAX(s.XtpStoragePct), MAX(s.AvgInstanceCpuPct), MAX(s.DtuLimit), MAX(s.CpuLimit)
            FROM   stg.ResourceUsage AS s
            WHERE  s.EndTimeUtc IS NOT NULL
              AND  NOT EXISTS (SELECT 1 FROM core.ResourceUsage c
                               WHERE c.ServerName = s.' + @S + N'
                                 AND c.DatabaseName = s.' + @D + N'
                                 AND c.EndTimeUtc = s.EndTimeUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.EndTimeUtc;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  ResourceUsage  +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'ResourceUsage', 'Frequent', 'ResourceUsage';
        END TRY BEGIN CATCH PRINT '!! ResourceUsage: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*========================================================== ActiveRequest */
    IF core.fn_StagingReady('ActiveRequest', @srv + ',' + @db + ',SnapshotUtc,SessionId') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.ActiveRequest
                (ServerName, DatabaseName, SnapshotUtc, SessionId, RequestId, Status, Command,
                 WaitType, WaitResource, WaitTimeMs, BlockingSessionId, OpenTranCount, CpuTimeMs,
                 TotalElapsedMs, LogicalReads, Writes, RowCountSoFar, GrantedMemoryKb, Dop,
                 LoginName, HostName, ProgramName, QueryHash, SqlText)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.SessionId, s.RequestId, s.Status,
                   s.Command, s.WaitType, s.WaitResource, s.WaitTimeMs, s.BlockingSessionId,
                   s.OpenTranCount, s.CpuTimeMs, s.TotalElapsedMs, s.LogicalReads, s.Writes,
                   s.RowCountSoFar, s.GrantedMemoryKb, s.Dop, s.LoginName, s.HostName,
                   s.ProgramName, s.QueryHash, s.SqlText
            FROM   stg.ActiveRequest AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.ActiveRequest c
                               WHERE c.ServerName = s.' + @S + N'
                                 AND c.DatabaseName = s.' + @D + N'
                                 AND c.SnapshotUtc = s.SnapshotUtc
                                 AND c.SessionId = s.SessionId);';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  ActiveRequest  +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'ActiveRequest', 'Frequent', 'ActiveRequest';
        END TRY BEGIN CATCH PRINT '!! ActiveRequest: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*========================================================== BlockingChain */
    IF core.fn_StagingReady('BlockingChain', @srv + ',' + @db + ',SnapshotUtc,BlockedSessionId') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.BlockingChain
                (ServerName, DatabaseName, SnapshotUtc, BlockedSessionId, BlockingSessionId,
                 HeadBlockerSessionId, ChainDepth, WaitType, WaitDurationMs, ResourceDescription,
                 BlockedLogin, BlockedProgram, BlockedSql, BlockerLogin, BlockerHost,
                 BlockerProgram, BlockerStatus, BlockerSql)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.BlockedSessionId, s.BlockingSessionId,
                   s.HeadBlockerSessionId, s.ChainDepth, s.WaitType, s.WaitDurationMs,
                   s.ResourceDescription, s.BlockedLogin, s.BlockedProgram, s.BlockedSql,
                   s.BlockerLogin, s.BlockerHost, s.BlockerProgram, s.BlockerStatus, s.BlockerSql
            FROM   stg.BlockingChain AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.BlockingChain c
                               WHERE c.ServerName = s.' + @S + N'
                                 AND c.DatabaseName = s.' + @D + N'
                                 AND c.SnapshotUtc = s.SnapshotUtc
                                 AND c.BlockedSessionId = s.BlockedSessionId);';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  BlockingChain  +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'BlockingChain', 'Frequent', 'BlockingChain';
        END TRY BEGIN CATCH PRINT '!! BlockingChain: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*======================================================== SessionActivity */
    IF core.fn_StagingReady('SessionActivity', @srv + ',' + @db + ',SnapshotUtc,ProgramName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.SessionActivity
                (ServerName, DatabaseName, SnapshotUtc, ProgramName, LoginName, HostName,
                 SessionCount, RunningCount, SleepingCount, BlockedCount, OpenTranCount)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.ProgramName, s.LoginName, s.HostName,
                   MAX(s.SessionCount), MAX(s.RunningCount), MAX(s.SleepingCount),
                   MAX(s.BlockedCount), MAX(s.OpenTranCount)
            FROM   stg.SessionActivity AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.SessionActivity c
                               WHERE c.ServerName = s.' + @S + N'
                                 AND c.DatabaseName = s.' + @D + N'
                                 AND c.SnapshotUtc = s.SnapshotUtc
                                 AND c.ProgramName = s.ProgramName
                                 AND c.LoginName = s.LoginName
                                 AND c.HostName = s.HostName)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.ProgramName, s.LoginName, s.HostName;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  SessionActivity +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'SessionActivity', 'Frequent', 'SessionActivity';
        END TRY BEGIN CATCH PRINT '!! SessionActivity: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*=============================================================== WaitStats */
    IF core.fn_StagingReady('WaitStats', @srv + ',' + @db + ',SnapshotUtc,WaitType') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.WaitStats
                (ServerName, DatabaseName, SnapshotUtc, WaitType, WaitingTasksCount,
                 WaitTimeMs, MaxWaitTimeMs, SignalWaitTimeMs)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.WaitType,
                   MAX(s.WaitingTasksCount), MAX(s.WaitTimeMs), MAX(s.MaxWaitTimeMs), MAX(s.SignalWaitTimeMs)
            FROM   stg.WaitStats AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.WaitStats c
                               WHERE c.ServerName = s.' + @S + N'
                                 AND c.DatabaseName = s.' + @D + N'
                                 AND c.SnapshotUtc = s.SnapshotUtc
                                 AND c.WaitType = s.WaitType)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.WaitType;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  WaitStats      +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'WaitStats', 'Frequent', 'WaitStats';
        END TRY BEGIN CATCH PRINT '!! WaitStats: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*============================================================== QueryStats */
    IF core.fn_StagingReady('QueryStats', @srv + ',' + @db + ',SnapshotUtc,QueryHash') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.QueryStats
                (ServerName, DatabaseName, SnapshotUtc, QueryHash, QueryPlanHash, ExecutionCount,
                 TotalWorkerTimeUs, TotalElapsedTimeUs, TotalLogicalReads, TotalLogicalWrites,
                 TotalPhysicalReads, TotalRows, ObjectName, SampleSqlText)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.QueryHash, s.QueryPlanHash,
                   MAX(s.ExecutionCount), MAX(s.TotalWorkerTimeUs), MAX(s.TotalElapsedTimeUs),
                   MAX(s.TotalLogicalReads), MAX(s.TotalLogicalWrites), MAX(s.TotalPhysicalReads),
                   MAX(s.TotalRows), MAX(s.ObjectName), MAX(s.SampleSqlText)
            FROM   stg.QueryStats AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.QueryStats c
                               WHERE c.ServerName = s.' + @S + N'
                                 AND c.DatabaseName = s.' + @D + N'
                                 AND c.QueryHash = s.QueryHash
                                 AND c.QueryPlanHash = s.QueryPlanHash
                                 AND c.SnapshotUtc = s.SnapshotUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.QueryHash, s.QueryPlanHash;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  QueryStats     +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'QueryStats', 'Standard', 'QueryStats';
        END TRY BEGIN CATCH PRINT '!! QueryStats: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*====================================================== QueryStoreTopQuery */
    IF core.fn_StagingReady('QueryStoreTopQuery', @srv + ',' + @db + ',QueryId,PlanId') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.QueryStoreTopQuery
                (ServerName, DatabaseName, SnapshotUtc, IntervalEndUtc, QueryId, PlanId, ObjectName,
                 ExecutionCount, AvgDurationMs, AvgCpuMs, TotalCpuMs, AvgLogicalReads,
                 AvgTempDbSpaceKb, AvgMemoryGrantKb, TopWaitCategory, QueryText)
            SELECT s.' + @S + N', s.' + @D + N', MAX(s.SnapshotUtc), s.IntervalEndUtc, s.QueryId, s.PlanId,
                   MAX(s.ObjectName), MAX(s.ExecutionCount), MAX(s.AvgDurationMs), MAX(s.AvgCpuMs),
                   MAX(s.TotalCpuMs), MAX(s.AvgLogicalReads), MAX(s.AvgTempDbSpaceKb),
                   MAX(s.AvgMemoryGrantKb), MAX(s.TopWaitCategory), MAX(s.QueryText)
            FROM   stg.QueryStoreTopQuery AS s
            WHERE  s.IntervalEndUtc IS NOT NULL
              AND  NOT EXISTS (SELECT 1 FROM core.QueryStoreTopQuery c
                               WHERE c.ServerName = s.' + @S + N'
                                 AND c.DatabaseName = s.' + @D + N'
                                 AND c.QueryId = s.QueryId AND c.PlanId = s.PlanId
                                 AND c.IntervalEndUtc = s.IntervalEndUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.IntervalEndUtc, s.QueryId, s.PlanId;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  QueryStore     +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'QueryStore', 'Standard', 'QueryStoreTopQuery';
        END TRY BEGIN CATCH PRINT '!! QueryStore: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*=================================================================== Space
      One landed row fans out into three core tables. SLO changes are detected
      here too, and only written when the value actually changes. */
    IF core.fn_StagingReady('Space', @srv + ',' + @db + ',SnapshotUtc') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.DatabaseSpace
                (ServerName, DatabaseName, SnapshotUtc, AllocatedMB, UsedMB, MaxSizeMB,
                 PctOfMaxSize, DataUsedMB, IndexUsedMB, ServiceObjective, Edition)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, MAX(s.AllocatedMB), MAX(s.UsedMB),
                   MAX(s.MaxSizeMB), MAX(s.PctOfMaxSize), MAX(s.DataUsedMB), MAX(s.IndexUsedMB),
                   MAX(s.ServiceObjective), MAX(s.Edition)
            FROM   stg.Space AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.DatabaseSpace c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.SnapshotUtc = s.SnapshotUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc;

            INSERT INTO core.LogSpace
                (ServerName, DatabaseName, SnapshotUtc, TotalLogSizeMB, UsedLogSpaceMB,
                 UsedLogSpacePct, LogReuseWaitDesc, OldestTranBeginUtc, OldestTranSessionId)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, MAX(s.TotalLogSizeMB),
                   MAX(s.UsedLogSpaceMB), MAX(s.UsedLogSpacePct), MAX(s.LogReuseWaitDesc),
                   MAX(s.OldestTranBeginUtc), MAX(s.OldestTranSessionId)
            FROM   stg.Space AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.LogSpace c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.SnapshotUtc = s.SnapshotUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc;

            INSERT INTO core.TempDbUsage
                (ServerName, DatabaseName, SnapshotUtc, TotalMB, AllocatedMB, PctUsed,
                 UserObjectsMB, InternalObjectsMB, VersionStoreMB)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, MAX(s.TempDbTotalMB),
                   MAX(s.TempDbAllocatedMB), MAX(s.TempDbPctUsed), MAX(s.TempDbUserMB),
                   MAX(s.TempDbInternalMB), MAX(s.TempDbVersionMB)
            FROM   stg.Space AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.TempDbUsage c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.SnapshotUtc = s.SnapshotUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc;

            WITH latest AS (
                SELECT ServerName = s.' + @S + N', DatabaseName = s.' + @D + N',
                       Slo = MAX(s.ServiceObjective), Edition = MAX(s.Edition),
                       MaxMB = MAX(s.MaxSizeMB), Utc = MAX(s.SnapshotUtc)
                FROM   stg.Space AS s GROUP BY s.' + @S + N', s.' + @D + N'),
            prev AS (
                SELECT c.ServerName, c.DatabaseName, c.ServiceObjective,
                       rn = ROW_NUMBER() OVER (PARTITION BY c.ServerName, c.DatabaseName
                                               ORDER BY c.DetectedUtc DESC)
                FROM   core.ServiceObjectiveChange AS c)
            INSERT INTO core.ServiceObjectiveChange
                (ServerName, DatabaseName, DetectedUtc, Edition, ServiceObjective, MaxSizeMB, PreviousObjective)
            SELECT l.ServerName, l.DatabaseName, l.Utc, l.Edition, l.Slo, l.MaxMB, p.ServiceObjective
            FROM   latest AS l
            LEFT JOIN prev AS p ON p.ServerName = l.ServerName
                               AND p.DatabaseName = l.DatabaseName AND p.rn = 1
            WHERE  p.ServiceObjective IS NULL OR ISNULL(p.ServiceObjective,N'''') <> ISNULL(l.Slo,N'''');';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  Space          +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'Space', 'Standard', 'Space';
        END TRY BEGIN CATCH PRINT '!! Space: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*============================================================= IoFileStats */
    IF core.fn_StagingReady('IoFileStats', @srv + ',' + @db + ',SnapshotUtc,FileId') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.IoFileStats
                (ServerName, DatabaseName, SnapshotUtc, FileId, FileName, TypeDesc, NumReads,
                 BytesRead, IoStallReadMs, NumWrites, BytesWritten, IoStallWriteMs, SizeOnDiskMB)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.FileId, MAX(s.FileName), MAX(s.TypeDesc),
                   MAX(s.NumReads), MAX(s.BytesRead), MAX(s.IoStallReadMs), MAX(s.NumWrites),
                   MAX(s.BytesWritten), MAX(s.IoStallWriteMs), MAX(s.SizeOnDiskMB)
            FROM   stg.IoFileStats AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.IoFileStats c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.FileId = s.FileId AND c.SnapshotUtc = s.SnapshotUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.FileId;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  IoFileStats    +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'Io', 'Standard', 'IoFileStats';
        END TRY BEGIN CATCH PRINT '!! IoFileStats: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*================================================================ XeErrors
      Deduplicated on (target, EventTimeUtc, EventSequence) - essential, because
      the ring buffer returns the same events on every harvest. Deadlock rows
      are split out into core.Deadlock. */
    IF core.fn_StagingReady('XeErrors', @srv + ',' + @db + ',EventTimeUtc,EventName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.ErrorEvent
                (ServerName, DatabaseName, EventTimeUtc, EventName, ErrorNumber, Severity,
                 ErrorState, Message, SessionId, LoginName, ProgramName, HostName, SqlText, EventSequence)
            SELECT s.' + @S + N', s.' + @D + N', s.EventTimeUtc, s.EventName, s.ErrorNumber, s.Severity,
                   s.ErrorState, s.Message, s.SessionId, s.LoginName, s.ProgramName, s.HostName,
                   s.SqlText, s.EventSequence
            FROM   stg.XeErrors AS s
            WHERE  s.EventName <> N''database_xml_deadlock_report''
              AND  s.EventTimeUtc IS NOT NULL
              AND  NOT EXISTS (SELECT 1 FROM core.ErrorEvent c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.EventTimeUtc = s.EventTimeUtc
                                 AND ISNULL(c.EventSequence,-1) = ISNULL(s.EventSequence,-1));

            INSERT INTO core.Deadlock
                (ServerName, DatabaseName, EventTimeUtc, VictimProcessId, ProcessCount,
                 ObjectsInvolved, VictimSql, VictimLogin, VictimProgram, DeadlockGraph, EventSequence)
            SELECT s.' + @S + N', s.' + @D + N', s.EventTimeUtc, s.VictimProcessId, s.ProcessCount,
                   s.ObjectsInvolved, s.ObjectsInvolved, s.LoginName, s.ProgramName,
                   TRY_CAST(s.DeadlockGraph AS xml), s.EventSequence
            FROM   stg.XeErrors AS s
            WHERE  s.EventName = N''database_xml_deadlock_report''
              AND  s.EventTimeUtc IS NOT NULL
              AND  NOT EXISTS (SELECT 1 FROM core.Deadlock c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.EventTimeUtc = s.EventTimeUtc
                                 AND ISNULL(c.EventSequence,-1) = ISNULL(s.EventSequence,-1));';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  XeErrors       +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'XeErrors', 'Standard', 'XeErrors';
        END TRY BEGIN CATCH PRINT '!! XeErrors: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*============================================================== XeBlocking */
    IF core.fn_StagingReady('XeBlocking', @srv + ',' + @db + ',EventTimeUtc') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.WaitEvent
                (ServerName, DatabaseName, EventTimeUtc, EventName, WaitType, DurationMs,
                 SessionId, LoginName, ProgramName, SqlText, EventSequence)
            SELECT s.' + @S + N', s.' + @D + N', s.EventTimeUtc, s.EventName, s.WaitType, s.DurationMs,
                   s.SessionId, s.LoginName, s.ProgramName, s.SqlText, s.EventSequence
            FROM   stg.XeBlocking AS s
            WHERE  s.EventTimeUtc IS NOT NULL
              AND  NOT EXISTS (SELECT 1 FROM core.WaitEvent c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.EventTimeUtc = s.EventTimeUtc
                                 AND ISNULL(c.EventSequence,-1) = ISNULL(s.EventSequence,-1));';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            IF @Debug = 1 PRINT '  XeBlocking     +' + CAST(@rows AS varchar(20));
            EXEC core.usp_RecordArrival 'XeBlocking', 'Standard', 'XeBlocking';
        END TRY BEGIN CATCH PRINT '!! XeBlocking: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*========================================================= XeSessionHealth */
    IF core.fn_StagingReady('XeSessionHealth', @srv + ',' + @db + ',SnapshotUtc,SessionName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO core.XeSessionHealth
                (ServerName, DatabaseName, SnapshotUtc, SessionName, State,
                 DroppedEventCount, DroppedBufferCount, Verdict)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.SessionName, MAX(s.State),
                   MAX(s.DroppedEventCount), MAX(s.DroppedBufferCount), MAX(s.Verdict)
            FROM   stg.XeSessionHealth AS s
            WHERE  NOT EXISTS (SELECT 1 FROM core.XeSessionHealth c
                               WHERE c.ServerName = s.' + @S + N' AND c.DatabaseName = s.' + @D + N'
                                 AND c.SessionName = s.SessionName AND c.SnapshotUtc = s.SnapshotUtc)
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotUtc, s.SessionName;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            EXEC core.usp_RecordArrival 'XeHealth', 'Standard', 'XeSessionHealth';
        END TRY BEGIN CATCH PRINT '!! XeSessionHealth: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    /*============================================================== DAILY FEEDS
      All keyed by SnapshotDate, so a re-run on the same day replaces rather
      than duplicates. */
    IF core.fn_StagingReady('IndexUsage', @srv + ',' + @db + ',SnapshotDate,SchemaName,TableName,IndexName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            DELETE c FROM core.IndexUsage c
            WHERE EXISTS (SELECT 1 FROM stg.IndexUsage s
                          WHERE s.' + @S + N' = c.ServerName AND s.' + @D + N' = c.DatabaseName
                            AND s.SnapshotDate = c.SnapshotDate);
            INSERT INTO core.IndexUsage
                (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, IndexName, IndexType,
                 IsUnique, IsPrimaryKey, KeyColumns, IncludedColumns, RowCountEst, SizeMB,
                 UserSeeks, UserScans, UserLookups, UserUpdates)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.SchemaName, s.TableName, s.IndexName,
                   MAX(s.IndexType), MAX(CAST(s.IsUnique AS tinyint)), MAX(CAST(s.IsPrimaryKey AS tinyint)),
                   MAX(s.KeyColumns), MAX(s.IncludedColumns), MAX(s.RowCountEst), MAX(s.SizeMB),
                   MAX(s.UserSeeks), MAX(s.UserScans), MAX(s.UserLookups), MAX(s.UserUpdates)
            FROM   stg.IndexUsage AS s
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.SchemaName, s.TableName, s.IndexName;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            EXEC core.usp_RecordArrival 'IndexUsage', 'Daily', 'IndexUsage';
        END TRY BEGIN CATCH PRINT '!! IndexUsage: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    IF core.fn_StagingReady('MissingIndex', @srv + ',' + @db + ',SnapshotDate') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            DELETE c FROM core.MissingIndex c
            WHERE EXISTS (SELECT 1 FROM stg.MissingIndex s
                          WHERE s.' + @S + N' = c.ServerName AND s.' + @D + N' = c.DatabaseName
                            AND s.SnapshotDate = c.SnapshotDate);
            INSERT INTO core.MissingIndex
                (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, EqualityColumns,
                 InequalityColumns, IncludedColumns, UserSeeks, AvgUserImpact, ImpactScore, CreateStatement)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.SchemaName, s.TableName,
                   s.EqualityColumns, s.InequalityColumns, s.IncludedColumns, s.UserSeeks,
                   s.AvgUserImpact, s.ImpactScore, s.CreateStatement
            FROM   stg.MissingIndex AS s;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            EXEC core.usp_RecordArrival 'MissingIndex', 'Daily', 'MissingIndex';
        END TRY BEGIN CATCH PRINT '!! MissingIndex: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    IF core.fn_StagingReady('IndexFragmentation', @srv + ',' + @db + ',SnapshotDate,SchemaName,TableName,IndexName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            DELETE c FROM core.IndexFragmentation c
            WHERE EXISTS (SELECT 1 FROM stg.IndexFragmentation s
                          WHERE s.' + @S + N' = c.ServerName AND s.' + @D + N' = c.DatabaseName
                            AND s.SnapshotDate = c.SnapshotDate);
            INSERT INTO core.IndexFragmentation
                (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, IndexName,
                 AvgFragmentationPct, PageCount)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.SchemaName, s.TableName, s.IndexName,
                   MAX(s.AvgFragmentationPct), MAX(s.PageCount)
            FROM   stg.IndexFragmentation AS s
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.SchemaName, s.TableName, s.IndexName;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            EXEC core.usp_RecordArrival 'Fragmentation', 'Daily', 'IndexFragmentation';
        END TRY BEGIN CATCH PRINT '!! IndexFragmentation: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    IF core.fn_StagingReady('TableSpace', @srv + ',' + @db + ',SnapshotDate,SchemaName,TableName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            DELETE c FROM core.TableSpace c
            WHERE EXISTS (SELECT 1 FROM stg.TableSpace s
                          WHERE s.' + @S + N' = c.ServerName AND s.' + @D + N' = c.DatabaseName
                            AND s.SnapshotDate = c.SnapshotDate);
            INSERT INTO core.TableSpace
                (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName,
                 RowCountEst, TotalMB, DataMB, IndexMB)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.SchemaName, s.TableName,
                   MAX(s.RowCountEst), MAX(s.TotalMB), MAX(s.DataMB), MAX(s.IndexMB)
            FROM   stg.TableSpace AS s
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.SchemaName, s.TableName;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            EXEC core.usp_RecordArrival 'TableSpace', 'Daily', 'TableSpace';
        END TRY BEGIN CATCH PRINT '!! TableSpace: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    IF core.fn_StagingReady('SecurityPrincipal', @srv + ',' + @db + ',SnapshotDate,PrincipalName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            DELETE c FROM core.SecurityPrincipal c
            WHERE EXISTS (SELECT 1 FROM stg.SecurityPrincipal s
                          WHERE s.' + @S + N' = c.ServerName AND s.' + @D + N' = c.DatabaseName
                            AND s.SnapshotDate = c.SnapshotDate);
            INSERT INTO core.SecurityPrincipal
                (ServerName, DatabaseName, SnapshotDate, PrincipalName, TypeDesc, AuthType,
                 CreateDateUtc, ModifyDateUtc, RoleMemberships)
            SELECT s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.PrincipalName, MAX(s.TypeDesc),
                   MAX(s.AuthType), MAX(s.CreateDateUtc), MAX(s.ModifyDateUtc), MAX(s.RoleMemberships)
            FROM   stg.SecurityPrincipal AS s
            GROUP BY s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.PrincipalName;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            EXEC core.usp_RecordArrival 'SecurityPrincipal', 'Daily', 'SecurityPrincipal';
        END TRY BEGIN CATCH PRINT '!! SecurityPrincipal: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    IF core.fn_StagingReady('SecurityPermission', @srv + ',' + @db + ',SnapshotDate,GranteeName') = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
            DELETE c FROM core.SecurityPermission c
            WHERE EXISTS (SELECT 1 FROM stg.SecurityPermission s
                          WHERE s.' + @S + N' = c.ServerName AND s.' + @D + N' = c.DatabaseName
                            AND s.SnapshotDate = c.SnapshotDate);
            INSERT INTO core.SecurityPermission
                (ServerName, DatabaseName, SnapshotDate, GranteeName, ClassDesc, ObjectName,
                 PermissionName, StateDesc)
            SELECT DISTINCT s.' + @S + N', s.' + @D + N', s.SnapshotDate, s.GranteeName,
                   s.ClassDesc, s.ObjectName, s.PermissionName, s.StateDesc
            FROM   stg.SecurityPermission AS s;';
            EXEC sys.sp_executesql @sql; SET @rows = @@ROWCOUNT; SET @total += @rows;
            EXEC core.usp_RecordArrival 'SecurityPermission', 'Daily', 'SecurityPermission';
        END TRY BEGIN CATCH PRINT '!! SecurityPermission: ' + ERROR_MESSAGE(); END CATCH;
    END ELSE SET @skipped += 1;

    UPDATE core.ProcessRun
       SET CompletedUtc = SYSUTCDATETIME(), Status = 'Success', RowsAffected = @total
     WHERE ProcessRunId = @RunId;

    SELECT RowsNormalized = @total, FeedsSkipped = @skipped;
    IF @skipped > 0
        RAISERROR('%d feed(s) skipped - staging table missing or column mismatch. Run tests\verify-staging-schema.sql.', 10, 1, @skipped);
END;
GO

/*==============================================================================
  STAGING CLEANUP - run after normalization
  Staging is a landing zone, not an archive. Rows are removed once they are
  older than Retention.StagingHours, in bounded batches.

  ------------------------------------------------------------------------------
  WHICH COLUMN SAYS HOW OLD A ROW IS
  ------------------------------------------------------------------------------
  An earlier version of this procedure selected only staging tables having a
  'last_modify_time' column. NO staging table has one - Elastic Jobs adds exactly
  one column of its own, internal_execution_id, and nothing else. So the cursor
  matched zero tables and THIS PROCEDURE SILENTLY PURGED NOTHING, on every run,
  for its entire life. Staging grew without bound while the purge reported
  success with an empty result set.

  Each feed carries its own timestamp, emitted by the collection query, so the
  age column is probed per table. A table with none is skipped LOUDLY rather
  than silently, because "nothing to purge" and "I cannot tell how old this is"
  must not look the same.
==============================================================================*/
CREATE OR ALTER PROCEDURE core.usp_PurgeStaging
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Hours int = cfg.fn_Int('Retention.StagingHours', 48);
    DECLARE @Batch int = cfg.fn_Int('Retention.PurgeBatchRows', 50000);
    DECLARE @Cut datetime2(3) = DATEADD(HOUR, -@Hours, SYSUTCDATETIME());

    DECLARE @t sysname, @col sysname, @sql nvarchar(max), @deleted int, @total bigint;
    DECLARE @Report TABLE (TableName sysname, AgeColumn sysname NULL,
                           RowsNow bigint NULL, OldestUtc datetime2(3) NULL,
                           RowsDeleted bigint NOT NULL DEFAULT (0));

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.name
        FROM   sys.tables  AS t
        JOIN   sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE  s.name = 'stg';
    OPEN c; FETCH NEXT FROM c INTO @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* same probe order as core.usp_RecordArrival - keep the two in step */
        SET @col = COALESCE(
            CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@t), 'SnapshotUtc')  IS NOT NULL THEN N'SnapshotUtc'  END,
            CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@t), 'EndTimeUtc')   IS NOT NULL THEN N'EndTimeUtc'   END,
            CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@t), 'EventTimeUtc') IS NOT NULL THEN N'EventTimeUtc' END,
            CASE WHEN COL_LENGTH('stg.' + QUOTENAME(@t), 'SnapshotDate') IS NOT NULL THEN N'SnapshotDate' END);

        SET @total = 0;

        IF @col IS NULL
        BEGIN
            /* Visible, not silent. This is the failure mode that hid the bug. */
            INSERT INTO @Report (TableName, AgeColumn, RowsNow, OldestUtc, RowsDeleted)
            VALUES ('stg.' + @t, NULL, NULL, NULL, 0);
            PRINT '!! purge stg.' + @t + ': no recognised timestamp column - NOT purged.';
        END
        ELSE
        BEGIN
            /* Report the current state BEFORE deleting, so "0 deleted" can always
               be explained: how many rows there are, and how old the oldest is
               relative to the cutoff. Without this, "nothing to purge" and
               "the purge is broken" produce an identical empty result set - which
               is exactly how a purge that had never worked went unnoticed. */
            DECLARE @rowsNow bigint, @oldest datetime2(3);
            SET @sql = N'SELECT @n = COUNT_BIG(*), @o = MIN(CONVERT(datetime2(3), '
                     + QUOTENAME(@col) + N')) FROM stg.' + QUOTENAME(@t) + N';';
            BEGIN TRY
                EXEC sys.sp_executesql @sql, N'@n bigint OUTPUT, @o datetime2(3) OUTPUT',
                     @n = @rowsNow OUTPUT, @o = @oldest OUTPUT;
            END TRY
            BEGIN CATCH SET @rowsNow = NULL; SET @oldest = NULL; END CATCH;

            SET @deleted = @Batch;
            SET @sql = N'DELETE TOP (@b) FROM stg.' + QUOTENAME(@t)
                     + N' WHERE CONVERT(datetime2(3), ' + QUOTENAME(@col) + N') < @c;';
            WHILE @deleted = @Batch
            BEGIN
                BEGIN TRY
                    EXEC sys.sp_executesql @sql, N'@b int, @c datetime2(3)', @b = @Batch, @c = @Cut;
                    SET @deleted = @@ROWCOUNT; SET @total += @deleted;
                END TRY
                BEGIN CATCH PRINT '!! purge stg.' + @t + ': ' + ERROR_MESSAGE(); SET @deleted = 0; END CATCH;
            END;

            INSERT INTO @Report (TableName, AgeColumn, RowsNow, OldestUtc, RowsDeleted)
            VALUES ('stg.' + @t, @col, @rowsNow, @oldest, @total);
        END;
        FETCH NEXT FROM c INTO @t;
    END;
    CLOSE c; DEALLOCATE c;

    /* ALWAYS return a row per staging table, even when nothing was deleted. */
    SELECT  TableName, AgeColumn,
            RowsBefore  = RowsNow,
            OldestUtc,
            AgeHours    = DATEDIFF(HOUR, OldestUtc, SYSUTCDATETIME()),
            CutoffUtc   = @Cut,
            RowsDeleted,
            Verdict = CASE
                WHEN AgeColumn IS NULL        THEN 'NOT PURGED - no timestamp column found'
                WHEN RowsDeleted > 0          THEN 'purged'
                WHEN RowsNow = 0              THEN 'nothing to purge - table is empty'
                WHEN OldestUtc >= @Cut        THEN 'nothing to purge - all rows are newer than the '
                                                 + CAST(@Hours AS varchar(10)) + ' hour retention window'
                ELSE 'nothing deleted - investigate' END
    FROM    @Report
    ORDER BY CASE WHEN AgeColumn IS NULL THEN 0 ELSE 1 END, RowsDeleted DESC, TableName;

    PRINT 'Retention.StagingHours = ' + CAST(@Hours AS varchar(10))
        + '  (cutoff ' + CONVERT(varchar(30), @Cut, 126) + ')';
END;
GO

PRINT '=== normalizer and staging purge deployed ===';
GO
