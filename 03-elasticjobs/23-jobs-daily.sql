/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 03-elasticjobs/23-jobs-daily.sql
  Run in : THE database (Elastic Job Agent + central repository)
  Tier   : DAILY - 02:30 UTC

  Six read-only steps. These are the heavy ones - particularly Fragmentation,
  which reads sys.dm_db_index_physical_stats - so they run once, off-peak, with
  generous timeouts.

  FRAGMENTATION USES LIMITED MODE. It reads only the top level of each b-tree,
  which is cheap. SAMPLED or DETAILED give page-density data at a cost that is
  not acceptable across an estate, and certainly not against a vendor database
  you do not own.
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

/*------------------------------------------------------------------------------
  CENTRAL SERVER
  The repository IS this database, so the output server is by definition the
  server you are connected to. The literal below documents intent; the live
  connection is the authority. If they disagree, the connection wins and says so.
------------------------------------------------------------------------------*/
DECLARE @OutServer nvarchar(256) = N'ehd-server.database.windows.net';   -- EDIT HERE if the server is renamed or moved
DECLARE @OutDb     nvarchar(128) = DB_NAME();   -- single-database design: results land here
DECLARE @Job       nvarchar(128) = N'EHD_Collect_Daily';

DECLARE @Connected sysname = CONVERT(sysname, SERVERPROPERTY('ServerName'));
IF @Connected IS NOT NULL
BEGIN
    IF @Connected NOT LIKE N'%.%' SET @Connected = @Connected + N'.database.windows.net';
    IF LOWER(@Connected) <> LOWER(@OutServer)
    BEGIN
        PRINT N'NOTE: literal @OutServer (' + @OutServer + N') differs from this connection - using ' + @Connected + N'.';
        SET @OutServer = @Connected;
    END
END

IF NOT EXISTS (SELECT 1 FROM jobs.jobs WHERE job_name = @Job)
    EXEC jobs.sp_add_job
         @job_name = @Job,
         @description = N'Index usage, missing indexes, fragmentation, table space, security',
         @enabled = 1,
         @schedule_interval_type = N'Days', @schedule_interval_count = 1,
         @schedule_start_time = '2026-01-01 02:30:00';
GO

/*------------------------------------------------------------------------------
  MAKE REDEPLOYMENT ACTUALLY REDEPLOY - see 21-jobs-frequent.sql for the full
  reasoning. Without this, an edited @command would be silently ignored on a
  redeploy because every sp_add_jobstep below is guarded by IF NOT EXISTS.
  The JOB is left alone, so execution history survives.
------------------------------------------------------------------------------*/
DECLARE @Job nvarchar(128) = N'EHD_Collect_Daily';
DECLARE @steps TABLE (StepName nvarchar(128) PRIMARY KEY);

INSERT INTO @steps (StepName)
SELECT js.step_name
FROM   jobs.jobsteps AS js
JOIN   jobs.jobs     AS j
  ON   j.job_id = js.job_id AND j.job_version = js.job_version
WHERE  j.job_name = @Job;

DECLARE @step nvarchar(128);
WHILE EXISTS (SELECT 1 FROM @steps)
BEGIN
    SELECT TOP (1) @step = StepName FROM @steps ORDER BY StepName;
    EXEC jobs.sp_delete_jobstep @job_name = @Job, @step_name = @step;
    DELETE FROM @steps WHERE StepName = @step;
END
GO

/* Repeated because T-SQL variables do not survive a GO. Same rule: literal
   documents intent, live connection is the authority. */
DECLARE @OutServer nvarchar(256) = N'ehd-server.database.windows.net';   -- EDIT HERE too if the server is renamed or moved
DECLARE @OutDb     nvarchar(128) = DB_NAME();   -- single-database design: results land here
DECLARE @Group     nvarchar(128) = N'EHD_AllTargets';
DECLARE @Job       nvarchar(128) = N'EHD_Collect_Daily';
DECLARE @cmd       nvarchar(max);

DECLARE @Connected sysname = CONVERT(sysname, SERVERPROPERTY('ServerName'));
IF @Connected IS NOT NULL
BEGIN
    IF @Connected NOT LIKE N'%.%' SET @Connected = @Connected + N'.database.windows.net';
    IF LOWER(@Connected) <> LOWER(@OutServer) SET @OutServer = @Connected;
END

/*------------------------------------------------------------------------------
  STEP 1  IndexUsage
  dm_db_index_usage_stats is cumulative and RESETS on failover, scale or an
  index rebuild. Daily snapshots let the central store compute a trustworthy
  "unused since" answer rather than trusting a counter that cannot be dated.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotDate    = CAST(SYSUTCDATETIME() AS date),
        SchemaName      = SCHEMA_NAME(t.schema_id),
        TableName       = t.name,
        IndexName       = ISNULL(i.name, N''(heap)''),
        IndexType       = i.type_desc,
        IsUnique        = i.is_unique,
        IsPrimaryKey    = i.is_primary_key,
        KeyColumns      = kc.KeyColumns,
        IncludedColumns = ic2.IncludedColumns,
        RowCountEst     = ps.RowCountEst,
        SizeMB          = ps.SizeMB,
        UserSeeks       = ISNULL(us.user_seeks, 0),
        UserScans       = ISNULL(us.user_scans, 0),
        UserLookups     = ISNULL(us.user_lookups, 0),
        UserUpdates     = ISNULL(us.user_updates, 0)
FROM    sys.indexes AS i
JOIN    sys.tables  AS t ON t.object_id = i.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
       ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
CROSS APPLY (
    SELECT RowCountEst = SUM(CASE WHEN p.index_id IN (0,1) THEN p.row_count ELSE 0 END),
           SizeMB      = CAST(SUM(p.used_page_count) * 8.0 / 1024 AS decimal(19,2))
    FROM   sys.dm_db_partition_stats AS p
    WHERE  p.object_id = i.object_id AND p.index_id = i.index_id) AS ps
OUTER APPLY (
    SELECT KeyColumns = STUFF((
        SELECT N'', '' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N'' DESC'' ELSE N'''' END
        FROM   sys.index_columns AS ic
        JOIN   sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
        ORDER BY ic.key_ordinal FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, N'''')) AS kc
OUTER APPLY (
    SELECT IncludedColumns = STUFF((
        SELECT N'', '' + QUOTENAME(c.name)
        FROM   sys.index_columns AS ic
        JOIN   sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
        ORDER BY ic.index_column_id FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, N'''')) AS ic2
WHERE   t.is_ms_shipped = 0;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'IndexUsage')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'IndexUsage', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'IndexUsage',
         @retry_attempts = 1, @step_timeout_seconds = 1800;

/*------------------------------------------------------------------------------
  STEP 2  MissingIndexes
  The optimizer's suggestions with the conventional impact score. The generated
  CREATE statement is a STARTING POINT, never something to run blind: the DMV
  ignores existing indexes, column order and write amplification.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
SELECT TOP (25)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotDate      = CAST(SYSUTCDATETIME() AS date),
        SchemaName        = OBJECT_SCHEMA_NAME(d.object_id),
        TableName         = OBJECT_NAME(d.object_id),
        EqualityColumns   = d.equality_columns,
        InequalityColumns = d.inequality_columns,
        IncludedColumns   = d.included_columns,
        UserSeeks         = gs.user_seeks,
        AvgUserImpact     = gs.avg_user_impact,
        ImpactScore       = CAST(gs.avg_total_user_cost * gs.avg_user_impact
                                 * (gs.user_seeks + gs.user_scans) / 100.0 AS float),
        CreateStatement   = N''CREATE NONCLUSTERED INDEX [IX_'' + OBJECT_NAME(d.object_id) + N''_''
              + REPLACE(REPLACE(REPLACE(ISNULL(d.equality_columns, N'''')
                  + ISNULL(N''_'' + d.inequality_columns, N''''), N'', '', N''_''), N''['', N''''), N'']'', N'''')
              + N''] ON '' + d.statement + N'' ('' + ISNULL(d.equality_columns, N'''')
              + CASE WHEN d.equality_columns IS NOT NULL AND d.inequality_columns IS NOT NULL THEN N'', '' ELSE N'''' END
              + ISNULL(d.inequality_columns, N'''') + N'')''
              + ISNULL(N'' INCLUDE ('' + d.included_columns + N'')'', N'''')
              + N'' WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);''
FROM    sys.dm_db_missing_index_group_stats AS gs
JOIN    sys.dm_db_missing_index_groups      AS g ON g.index_group_handle = gs.group_handle
JOIN    sys.dm_db_missing_index_details     AS d ON d.index_handle = g.index_handle
WHERE   d.database_id = DB_ID()
ORDER BY gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) DESC;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'MissingIndexes')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'MissingIndexes', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'MissingIndex',
         @retry_attempts = 1, @step_timeout_seconds = 600;

/*------------------------------------------------------------------------------
  STEP 3  Fragmentation - LIMITED mode, indexes of 1000+ pages only
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
SELECT TOP (200)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotDate        = CAST(SYSUTCDATETIME() AS date),
        SchemaName          = OBJECT_SCHEMA_NAME(ps.object_id),
        TableName           = OBJECT_NAME(ps.object_id),
        IndexName           = i.name,
        AvgFragmentationPct = CAST(ps.avg_fragmentation_in_percent AS decimal(9,4)),
        PageCount           = ps.page_count
FROM    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''LIMITED'') AS ps
JOIN    sys.indexes AS i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE   ps.page_count >= 1000
  AND   ps.index_id > 0
  AND   i.name IS NOT NULL
ORDER BY ps.page_count DESC;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'Fragmentation')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'Fragmentation', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'IndexFragmentation',
         @retry_attempts = 1, @step_timeout_seconds = 3600;

/*------------------------------------------------------------------------------
  STEP 4  TableSpace - growth trending per table
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
SELECT TOP (100)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotDate = CAST(SYSUTCDATETIME() AS date),
        SchemaName   = SCHEMA_NAME(t.schema_id),
        TableName    = t.name,
        RowCountEst  = SUM(CASE WHEN p.index_id IN (0,1) THEN p.row_count ELSE 0 END),
        TotalMB      = CAST(SUM(p.reserved_page_count) * 8.0 / 1024 AS decimal(19,2)),
        DataMB       = CAST(SUM(CASE WHEN p.index_id IN (0,1)
                          THEN p.in_row_data_page_count + p.lob_used_page_count + p.row_overflow_used_page_count
                          ELSE 0 END) * 8.0 / 1024 AS decimal(19,2)),
        IndexMB      = CAST(SUM(CASE WHEN p.index_id NOT IN (0,1) THEN p.used_page_count ELSE 0 END)
                          * 8.0 / 1024 AS decimal(19,2))
FROM    sys.tables AS t
JOIN    sys.dm_db_partition_stats AS p ON p.object_id = t.object_id
WHERE   t.is_ms_shipped = 0
GROUP BY t.schema_id, t.name
ORDER BY SUM(p.reserved_page_count) DESC;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'TableSpace')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'TableSpace', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'TableSpace',
         @retry_attempts = 1, @step_timeout_seconds = 900;

/*------------------------------------------------------------------------------
  STEP 5  SecurityPrincipals - daily fingerprint, diffed centrally.
  Reads principal metadata only. No application data is touched.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotDate    = CAST(SYSUTCDATETIME() AS date),
        PrincipalName   = p.name,
        TypeDesc        = p.type_desc,
        AuthType        = p.authentication_type_desc,
        CreateDateUtc   = p.create_date,
        ModifyDateUtc   = p.modify_date,
        RoleMemberships = STUFF((
            SELECT N'', '' + r.name
            FROM   sys.database_role_members AS rm
            JOIN   sys.database_principals   AS r ON r.principal_id = rm.role_principal_id
            WHERE  rm.member_principal_id = p.principal_id
            ORDER BY r.name FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, N'''')
FROM    sys.database_principals AS p
WHERE   p.type <> ''R'' AND p.principal_id > 4 AND p.name NOT LIKE ''##%'';';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'SecurityPrincipals')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'SecurityPrincipals', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'SecurityPrincipal',
         @retry_attempts = 1, @step_timeout_seconds = 300;

/*------------------------------------------------------------------------------
  STEP 6  SecurityPermissions - explicit grants and denies
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
SELECT TOP (2000)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotDate   = CAST(SYSUTCDATETIME() AS date),
        GranteeName    = gp.name,
        ClassDesc      = dp.class_desc,
        ObjectName     = CASE dp.class
             WHEN 0 THEN N''DATABASE::'' + DB_NAME()
             WHEN 1 THEN ISNULL(QUOTENAME(OBJECT_SCHEMA_NAME(dp.major_id)) + N''.'' + QUOTENAME(OBJECT_NAME(dp.major_id)),
                                N''(object '' + CAST(dp.major_id AS nvarchar(20)) + N'')'')
             WHEN 3 THEN N''SCHEMA::'' + ISNULL(SCHEMA_NAME(dp.major_id), CAST(dp.major_id AS nvarchar(20)))
             WHEN 4 THEN N''PRINCIPAL::'' + ISNULL(USER_NAME(dp.major_id), CAST(dp.major_id AS nvarchar(20)))
             ELSE dp.class_desc + N''::'' + CAST(dp.major_id AS nvarchar(20)) END,
        PermissionName = dp.permission_name,
        StateDesc      = dp.state_desc
FROM    sys.database_permissions AS dp
JOIN    sys.database_principals  AS gp ON gp.principal_id = dp.grantee_principal_id
WHERE   gp.name <> ''public'' AND dp.major_id >= 0;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'SecurityPermissions')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'SecurityPermissions', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'SecurityPermission',
         @retry_attempts = 1, @step_timeout_seconds = 300;
GO

/*==============================================================================
  The optional target-setup job lives in its own file: 25-jobs-setup.sql.

  It is separated deliberately. It is the only job that WRITES to a target
  (XE sessions + Query Store), and keeping it apart is what lets
  tests\Test-EmbeddedCommands.ps1 prove that everything in THIS file is
  read-only. It is also created disabled and unscheduled, so it never touches a
  vendor database unless you start it by hand.
==============================================================================*/
GO

SELECT  j.job_name, js.step_id, js.step_name, js.output_table_name, js.step_timeout_seconds
FROM    jobs.jobsteps AS js
JOIN    jobs.jobs     AS j ON j.job_id = js.job_id AND j.job_version = js.job_version
WHERE   j.job_name LIKE N'EHD[_]%'
ORDER BY j.job_name, js.step_id;
GO
