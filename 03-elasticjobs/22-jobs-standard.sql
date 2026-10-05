/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 03-elasticjobs/22-jobs-standard.sql
  Run in : THE database (Elastic Job Agent + central repository)
  Tier   : STANDARD - every 30 minutes

  Seven read-only steps. Two of them harvest the Extended Events ring buffers
  deployed by 02-targets/11-target-xe-sessions.sql.

  ------------------------------------------------------------------------------
  THE RING BUFFER HARVEST IS WHAT MAKES A 30-MINUTE CADENCE VIABLE
  ------------------------------------------------------------------------------
  Polling sees only the instant it looks. The XE sessions watch continuously
  and hold recent events in memory, so a deadlock that lasted 200 ms at 03:14
  is still collected by the 03:30 run.

  The ring buffer is re-read in full every time and returns the same events
  until they age out, so every harvested row carries event_sequence. The
  central normalizer de-duplicates on (target, EventTimeUtc, EventSequence).
  Harvesting twice is therefore harmless - which matters, because retries are
  normal.

  If a target has no XE session (tier limitation, or you chose not to deploy
  one), the step returns an empty result set rather than failing.
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
DECLARE @Job       nvarchar(128) = N'EHD_Collect_Standard';

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
         @description = N'Query stats, Query Store, space, IO, XE harvest, SLO',
         @enabled = 1,
         @schedule_interval_type = N'Minutes', @schedule_interval_count = 30;
GO

/*------------------------------------------------------------------------------
  MAKE REDEPLOYMENT ACTUALLY REDEPLOY - see 21-jobs-frequent.sql for the full
  reasoning. Without this, an edited @command would be silently ignored on a
  redeploy because every sp_add_jobstep below is guarded by IF NOT EXISTS.
  The JOB is left alone, so execution history survives.
------------------------------------------------------------------------------*/
DECLARE @Job nvarchar(128) = N'EHD_Collect_Standard';
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
DECLARE @Job       nvarchar(128) = N'EHD_Collect_Standard';
DECLARE @cmd       nvarchar(max);

DECLARE @Connected sysname = CONVERT(sysname, SERVERPROPERTY('ServerName'));
IF @Connected IS NOT NULL
BEGIN
    IF @Connected NOT LIKE N'%.%' SET @Connected = @Connected + N'.database.windows.net';
    IF LOWER(@Connected) <> LOWER(@OutServer) SET @OutServer = @Connected;
END

/*------------------------------------------------------------------------------
  STEP 1  QueryStats - cumulative per (query_hash, plan_hash).
  TOP 25 by worker time keeps the payload bounded; the central delta view turns
  the cumulative totals into per-interval figures.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
SELECT TOP (25)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc        = @Now,
        QueryHash          = CONVERT(varchar(20), qs.query_hash, 1),
        QueryPlanHash      = CONVERT(varchar(20), qs.query_plan_hash, 1),
        ExecutionCount     = SUM(qs.execution_count),
        TotalWorkerTimeUs  = SUM(qs.total_worker_time),
        TotalElapsedTimeUs = SUM(qs.total_elapsed_time),
        TotalLogicalReads  = SUM(qs.total_logical_reads),
        TotalLogicalWrites = SUM(qs.total_logical_writes),
        TotalPhysicalReads = SUM(qs.total_physical_reads),
        TotalRows          = SUM(qs.total_rows),
        ObjectName         = MIN(QUOTENAME(OBJECT_SCHEMA_NAME(t.objectid)) + N''.'' + QUOTENAME(OBJECT_NAME(t.objectid))),
        SampleSqlText      = MIN(LEFT(REPLACE(REPLACE(t.text, CHAR(13), '' ''), CHAR(10), '' ''), 4000))
FROM    sys.dm_exec_query_stats AS qs
OUTER APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE   qs.query_hash IS NOT NULL
GROUP BY qs.query_hash, qs.query_plan_hash
ORDER BY SUM(qs.total_worker_time) DESC;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'QueryStats')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'QueryStats', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'QueryStats',
         @retry_attempts = 2, @step_timeout_seconds = 300;

/*------------------------------------------------------------------------------
  STEP 2  QueryStore - the most recent CLOSED interval.
  Guarded: if Query Store is off or unreadable the step returns an empty set
  with the right column shape instead of erroring.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM sys.database_query_store_options
               WHERE actual_state_desc IN (''READ_WRITE'',''READ_ONLY''))
BEGIN
    SELECT TOP (0)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc = @Now, IntervalEndUtc = CAST(NULL AS datetimeoffset(7)),
        QueryId = CAST(0 AS bigint), PlanId = CAST(0 AS bigint),
        ObjectName = CAST(NULL AS nvarchar(512)), ExecutionCount = CAST(0 AS bigint),
        AvgDurationMs = CAST(0 AS decimal(19,3)), AvgCpuMs = CAST(0 AS decimal(19,3)),
        TotalCpuMs = CAST(0 AS decimal(19,3)), AvgLogicalReads = CAST(0 AS decimal(19,3)),
        AvgTempDbSpaceKb = CAST(0 AS decimal(19,3)), AvgMemoryGrantKb = CAST(0 AS decimal(19,3)),
        TopWaitCategory = CAST(NULL AS nvarchar(60)), QueryText = CAST(NULL AS nvarchar(4000));
    RETURN;
END;
DECLARE @IntervalId bigint, @IntEnd datetimeoffset(7);
SELECT TOP (1) @IntervalId = runtime_stats_interval_id, @IntEnd = end_time
FROM   sys.query_store_runtime_stats_interval
WHERE  end_time <= SYSDATETIMEOFFSET()
ORDER BY end_time DESC;
WITH waits AS (
    SELECT ws.plan_id, ws.wait_category_desc,
           rn = ROW_NUMBER() OVER (PARTITION BY ws.plan_id ORDER BY ws.avg_query_wait_time_ms DESC)
    FROM   sys.query_store_wait_stats AS ws
    WHERE  ws.runtime_stats_interval_id = @IntervalId
)
SELECT TOP (25)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc      = @Now,
        IntervalEndUtc   = @IntEnd,
        QueryId          = q.query_id,
        PlanId           = p.plan_id,
        ObjectName       = CASE WHEN q.object_id = 0 THEN N''(ad hoc)''
                                ELSE QUOTENAME(OBJECT_SCHEMA_NAME(q.object_id)) + N''.'' + QUOTENAME(OBJECT_NAME(q.object_id)) END,
        ExecutionCount   = rs.count_executions,
        AvgDurationMs    = CAST(rs.avg_duration / 1000.0 AS decimal(19,3)),
        AvgCpuMs         = CAST(rs.avg_cpu_time / 1000.0 AS decimal(19,3)),
        TotalCpuMs       = CAST(rs.avg_cpu_time * rs.count_executions / 1000.0 AS decimal(19,3)),
        AvgLogicalReads  = CAST(rs.avg_logical_io_reads AS decimal(19,3)),
        AvgTempDbSpaceKb = CAST(rs.avg_tempdb_space_used * 8.0 AS decimal(19,3)),
        AvgMemoryGrantKb = CAST(rs.avg_query_max_used_memory * 8.0 AS decimal(19,3)),
        TopWaitCategory  = w.wait_category_desc,
        QueryText        = LEFT(REPLACE(REPLACE(qt.query_sql_text, CHAR(13), '' ''), CHAR(10), '' ''), 4000)
FROM    sys.query_store_runtime_stats AS rs
JOIN    sys.query_store_plan          AS p  ON p.plan_id  = rs.plan_id
JOIN    sys.query_store_query         AS q  ON q.query_id = p.query_id
JOIN    sys.query_store_query_text    AS qt ON qt.query_text_id = q.query_text_id
LEFT JOIN waits AS w ON w.plan_id = p.plan_id AND w.rn = 1
WHERE   rs.runtime_stats_interval_id = @IntervalId
ORDER BY rs.avg_cpu_time * rs.count_executions DESC;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'QueryStore')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'QueryStore', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'QueryStoreTopQuery',
         @retry_attempts = 2, @step_timeout_seconds = 300;

/*------------------------------------------------------------------------------
  STEP 3  Space - database, log and tempdb in one result set
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
DECLARE @MaxSizeMB decimal(19,2) =
    TRY_CAST(DATABASEPROPERTYEX(DB_NAME(), ''MaxSizeInBytes'') AS decimal(19,2)) / 1048576.0;
DECLARE @LogTotal decimal(19,2), @LogUsed decimal(19,2), @LogPct decimal(9,4), @LogReuse nvarchar(60);
DECLARE @TdTotal decimal(19,2), @TdAlloc decimal(19,2), @TdUser decimal(19,2),
        @TdInternal decimal(19,2), @TdVersion decimal(19,2);
DECLARE @OldestTran datetime2(3), @OldestSpid smallint;

BEGIN TRY
    /* sys.dm_db_log_space_used is not present on every Azure SQL tier/platform.
       A direct reference is a COMPILE-TIME binding error, which BEGIN TRY cannot
       catch - the whole batch fails before the TRY block is ever entered, taking
       the entire Space feed with it. Deferring the bind into sp_executesql moves
       the failure to run time, where the OBJECT_ID guard prevents it entirely and
       the CATCH would handle anything else. Missing DMV = NULL log metrics, not a
       dead step. */
    IF OBJECT_ID(''sys.dm_db_log_space_used'') IS NOT NULL
    BEGIN
        DECLARE @logSql nvarchar(max) = N''SELECT TOP (1) @t = CAST(total_log_size_in_bytes / 1048576.0 AS decimal(19,2)), @u = CAST(used_log_space_in_bytes / 1048576.0 AS decimal(19,2)), @p = CAST(used_log_space_in_percent AS decimal(9,4)) FROM sys.dm_db_log_space_used;'';
        EXEC sys.sp_executesql @logSql,
             N''@t decimal(19,2) OUTPUT, @u decimal(19,2) OUTPUT, @p decimal(9,4) OUTPUT'',
             @t = @LogTotal OUTPUT, @u = @LogUsed OUTPUT, @p = @LogPct OUTPUT;
    END
    SELECT TOP (1) @LogReuse = log_reuse_wait_desc FROM sys.databases WHERE database_id = DB_ID();
    SELECT TOP (1) @OldestTran = at.transaction_begin_time, @OldestSpid = st.session_id
    FROM   sys.dm_tran_active_transactions AS at
    JOIN   sys.dm_tran_session_transactions AS st ON st.transaction_id = at.transaction_id
    WHERE  at.transaction_state = 2 ORDER BY at.transaction_begin_time;
END TRY BEGIN CATCH END CATCH;

BEGIN TRY
    /* Same deferred-bind reasoning as the log DMV above. tempdb.sys.database_files
       is a CROSS-DATABASE reference and sys.dm_db_file_space_used is not present
       on every tier; binding either directly would fail the batch at COMPILE time,
       which BEGIN TRY cannot catch. Each probe is independent, so one unavailable
       DMV costs one metric instead of the whole tempdb section.
       type = 0 is used instead of comparing type_desc to a string, purely to keep
       the inner SQL free of quotes - this is already two levels of nesting deep. */
    DECLARE @tdSql nvarchar(max);

    SET @tdSql = N''SELECT @t = CAST(SUM(size) * 8.0 / 1024 AS decimal(19,2)) FROM tempdb.sys.database_files WHERE type = 0;'';
    BEGIN TRY EXEC sys.sp_executesql @tdSql, N''@t decimal(19,2) OUTPUT'', @t = @TdTotal OUTPUT; END TRY BEGIN CATCH END CATCH;

    SET @tdSql = N''SELECT @u = CAST(SUM(u.user_objects_alloc_page_count - u.user_objects_dealloc_page_count) * 8.0 / 1024 AS decimal(19,2)), @i = CAST(SUM(u.internal_objects_alloc_page_count - u.internal_objects_dealloc_page_count) * 8.0 / 1024 AS decimal(19,2)) FROM sys.dm_db_session_space_usage AS u;'';
    BEGIN TRY EXEC sys.sp_executesql @tdSql, N''@u decimal(19,2) OUTPUT, @i decimal(19,2) OUTPUT'', @u = @TdUser OUTPUT, @i = @TdInternal OUTPUT; END TRY BEGIN CATCH END CATCH;

    SET @tdSql = N''SELECT @v = CAST(SUM(version_store_reserved_page_count) * 8.0 / 1024 AS decimal(19,2)) FROM sys.dm_db_file_space_used;'';
    BEGIN TRY EXEC sys.sp_executesql @tdSql, N''@v decimal(19,2) OUTPUT'', @v = @TdVersion OUTPUT; END TRY BEGIN CATCH END CATCH;

    SET @TdAlloc = ISNULL(@TdUser,0) + ISNULL(@TdInternal,0) + ISNULL(@TdVersion,0);
END TRY BEGIN CATCH END CATCH;

WITH ps AS (
    SELECT DataMB  = CAST(SUM(CASE WHEN p.index_id IN (0,1)
                        THEN p.in_row_data_page_count + p.lob_used_page_count + p.row_overflow_used_page_count
                        ELSE 0 END) * 8.0 / 1024 AS decimal(19,2)),
           IndexMB = CAST(SUM(CASE WHEN p.index_id NOT IN (0,1) THEN p.used_page_count ELSE 0 END) * 8.0 / 1024 AS decimal(19,2))
    FROM   sys.dm_db_partition_stats AS p
),
fs AS (
    SELECT AllocatedMB = CAST(SUM(f.size) * 8.0 / 1024 AS decimal(19,2)),
           UsedMB      = CAST(SUM(CAST(FILEPROPERTY(f.name, ''SpaceUsed'') AS bigint)) * 8.0 / 1024 AS decimal(19,2))
    FROM   sys.database_files AS f WHERE f.type_desc = ''ROWS''
)
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc         = @Now,
        AllocatedMB         = fs.AllocatedMB,
        UsedMB              = fs.UsedMB,
        MaxSizeMB           = @MaxSizeMB,
        PctOfMaxSize        = CASE WHEN @MaxSizeMB > 0 THEN CAST(fs.UsedMB * 100.0 / @MaxSizeMB AS decimal(9,4)) END,
        DataUsedMB          = ps.DataMB,
        IndexUsedMB         = ps.IndexMB,
        ServiceObjective    = CAST(DATABASEPROPERTYEX(DB_NAME(), ''ServiceObjective'') AS nvarchar(64)),
        Edition             = CAST(DATABASEPROPERTYEX(DB_NAME(), ''Edition'') AS nvarchar(64)),
        TotalLogSizeMB      = @LogTotal,
        UsedLogSpaceMB      = @LogUsed,
        UsedLogSpacePct     = @LogPct,
        LogReuseWaitDesc    = @LogReuse,
        OldestTranBeginUtc  = @OldestTran,
        OldestTranSessionId = @OldestSpid,
        TempDbTotalMB       = @TdTotal,
        TempDbAllocatedMB   = @TdAlloc,
        TempDbPctUsed       = CASE WHEN @TdTotal > 0 THEN CAST(@TdAlloc * 100.0 / @TdTotal AS decimal(9,4)) END,
        TempDbUserMB        = @TdUser,
        TempDbInternalMB    = @TdInternal,
        TempDbVersionMB     = @TdVersion
FROM    fs CROSS JOIN ps;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'Space')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'Space', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'Space',
         @retry_attempts = 2, @step_timeout_seconds = 300;

/*------------------------------------------------------------------------------
  STEP 4  Io - cumulative virtual file stats
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc    = @Now,
        FileId         = vfs.file_id,
        FileName       = df.name,
        TypeDesc       = df.type_desc,
        NumReads       = vfs.num_of_reads,
        BytesRead      = vfs.num_of_bytes_read,
        IoStallReadMs  = vfs.io_stall_read_ms,
        NumWrites      = vfs.num_of_writes,
        BytesWritten   = vfs.num_of_bytes_written,
        IoStallWriteMs = vfs.io_stall_write_ms,
        SizeOnDiskMB   = CAST(vfs.size_on_disk_bytes / 1048576.0 AS decimal(19,2))
FROM    sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS vfs
LEFT JOIN sys.database_files AS df ON df.file_id = vfs.file_id;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'Io')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'Io', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'IoFileStats',
         @retry_attempts = 2, @step_timeout_seconds = 300;

/*------------------------------------------------------------------------------
  STEP 5  XeErrors - shred the ehd_errors ring buffer.
  Deadlock graphs are returned as nvarchar rather than xml, because Elastic
  Jobs output tables handle character data far more predictably than xml. The
  central normalizer casts it back.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
DECLARE @x xml = (
    SELECT TOP (1) TRY_CAST(t.target_data AS xml)
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = N''ehd_errors'' AND t.target_name = N''ring_buffer'');
IF @x IS NULL
BEGIN
    SELECT TOP (0)
        HarvestUtc = @Now, EventTimeUtc = CAST(NULL AS datetime2(3)),
        EventName = CAST(NULL AS sysname), ErrorNumber = CAST(NULL AS int),
        Severity = CAST(NULL AS int), ErrorState = CAST(NULL AS int),
        Message = CAST(NULL AS nvarchar(4000)), SessionId = CAST(NULL AS int),
        LoginName = CAST(NULL AS nvarchar(256)), ProgramName = CAST(NULL AS nvarchar(256)),
        HostName = CAST(NULL AS nvarchar(256)), SqlText = CAST(NULL AS nvarchar(4000)),
        EventSequence = CAST(NULL AS bigint), DeadlockGraph = CAST(NULL AS nvarchar(max)),
        VictimProcessId = CAST(NULL AS nvarchar(50)), ProcessCount = CAST(NULL AS int),
        ObjectsInvolved = CAST(NULL AS nvarchar(4000));
    RETURN;
END;
SELECT  HarvestUtc    = @Now,
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        EventTimeUtc  = ev.value(''@timestamp'', ''datetime2(3)''),
        EventName     = ev.value(''@name'', ''sysname''),
        ErrorNumber   = ev.value(''(data[@name="error_number"]/value)[1]'', ''int''),
        Severity      = ev.value(''(data[@name="severity"]/value)[1]'', ''int''),
        ErrorState    = ev.value(''(data[@name="state"]/value)[1]'', ''int''),
        Message       = LEFT(ev.value(''(data[@name="message"]/value)[1]'', ''nvarchar(max)''), 4000),
        SessionId     = ev.value(''(action[@name="session_id"]/value)[1]'', ''int''),
        LoginName     = ev.value(''(action[@name="server_principal_name"]/value)[1]'', ''nvarchar(256)''),
        ProgramName   = ev.value(''(action[@name="client_app_name"]/value)[1]'', ''nvarchar(256)''),
        HostName      = ev.value(''(action[@name="client_hostname"]/value)[1]'', ''nvarchar(256)''),
        SqlText       = LEFT(ev.value(''(action[@name="sql_text"]/value)[1]'', ''nvarchar(max)''), 4000),
        EventSequence = ev.value(''(action[@name="event_sequence"]/value)[1]'', ''bigint''),
        DeadlockGraph = CAST(ev.query(''(data[@name="xml_report"]/value/deadlock)[1]'') AS nvarchar(max)),
        VictimProcessId = ev.value(''(data[@name="xml_report"]/value/deadlock/victim-list/victimProcess/@id)[1]'', ''nvarchar(50)''),
        ProcessCount    = ev.value(''count(data[@name="xml_report"]/value/deadlock/process-list/process)'', ''int''),
        ObjectsInvolved = LEFT(ev.value(''(data[@name="xml_report"]/value/deadlock/process-list/process/inputbuf)[1]'', ''nvarchar(max)''), 4000)
FROM    @x.nodes(''/RingBufferTarget/event'') AS q(ev);';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'XeErrors')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'XeErrors', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'XeErrors',
         @retry_attempts = 1, @step_timeout_seconds = 300;

/*------------------------------------------------------------------------------
  STEP 6  XeBlocking - shred the ehd_blocking ring buffer
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
DECLARE @x xml = (
    SELECT TOP (1) TRY_CAST(t.target_data AS xml)
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s ON s.address = t.event_session_address
    WHERE  s.name = N''ehd_blocking'' AND t.target_name = N''ring_buffer'');
IF @x IS NULL
BEGIN
    SELECT TOP (0)
        HarvestUtc = @Now, EventTimeUtc = CAST(NULL AS datetime2(3)),
        EventName = CAST(NULL AS sysname), WaitType = CAST(NULL AS nvarchar(128)),
        DurationMs = CAST(NULL AS bigint), SessionId = CAST(NULL AS int),
        LoginName = CAST(NULL AS nvarchar(256)), ProgramName = CAST(NULL AS nvarchar(256)),
        SqlText = CAST(NULL AS nvarchar(4000)), EventSequence = CAST(NULL AS bigint);
    RETURN;
END;
SELECT  HarvestUtc    = @Now,
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        EventTimeUtc  = ev.value(''@timestamp'', ''datetime2(3)''),
        EventName     = ev.value(''@name'', ''sysname''),
        WaitType      = ev.value(''(data[@name="wait_type"]/text)[1]'', ''nvarchar(128)''),
        DurationMs    = ev.value(''(data[@name="duration"]/value)[1]'', ''bigint''),
        SessionId     = ev.value(''(action[@name="session_id"]/value)[1]'', ''int''),
        LoginName     = ev.value(''(action[@name="server_principal_name"]/value)[1]'', ''nvarchar(256)''),
        ProgramName   = ev.value(''(action[@name="client_app_name"]/value)[1]'', ''nvarchar(256)''),
        SqlText       = LEFT(ev.value(''(action[@name="sql_text"]/value)[1]'', ''nvarchar(max)''), 4000),
        EventSequence = ev.value(''(action[@name="event_sequence"]/value)[1]'', ''bigint'')
FROM    @x.nodes(''/RingBufferTarget/event'') AS q(ev);';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'XeBlocking')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'XeBlocking', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'XeBlocking',
         @retry_attempts = 1, @step_timeout_seconds = 300;

/*------------------------------------------------------------------------------
  STEP 7  XeHealth - are the sessions actually running and not dropping events?
  A monitoring feed that silently stops is worse than no feed.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc        = @Now,
        SessionName        = s.name,
        State              = CASE WHEN r.name IS NULL THEN ''STOPPED'' ELSE ''RUNNING'' END,
        DroppedEventCount  = ISNULL(r.dropped_event_count, 0),
        DroppedBufferCount = ISNULL(r.dropped_buffer_count, 0),
        Verdict = CASE WHEN r.name IS NULL              THEN N''NOT RUNNING - no data being captured''
                       WHEN r.blocked_event_fire_time>0 THEN N''Blocking the workload''
                       WHEN r.dropped_buffer_count   >0 THEN N''Dropping buffers - raise MAX_MEMORY''
                       WHEN r.dropped_event_count >1000 THEN N''Dropping events - tighten predicates''
                       ELSE N''Healthy'' END
FROM    sys.database_event_sessions AS s
LEFT   JOIN sys.dm_xe_database_sessions AS r ON r.name = s.name
WHERE   s.name LIKE ''ehd[_]%'';';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'XeHealth')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'XeHealth', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'XeSessionHealth',
         @retry_attempts = 1, @step_timeout_seconds = 120;
GO

SELECT  j.job_name, js.step_id, js.step_name, js.output_table_name
FROM    jobs.jobsteps AS js
JOIN    jobs.jobs     AS j ON j.job_id = js.job_id AND j.job_version = js.job_version
WHERE   j.job_name = N'EHD_Collect_Standard'
ORDER BY js.step_id;
GO
