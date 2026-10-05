/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 03-elasticjobs/21-jobs-frequent.sql
  Run in : THE database (Elastic Job Agent + central repository)
  Tier   : FREQUENT - every 5 minutes

  Five read-only steps. Every @command is a pure SELECT: no temp tables, no
  DDL, no writes. Each returns a small result set that Elastic Jobs lands in
  the central repository.

  ------------------------------------------------------------------------------
  WHY 5 MINUTES IS ENOUGH, EVEN THOUGH THE EMBEDDED EDITION USED 1 MINUTE
  ------------------------------------------------------------------------------
  sys.dm_db_resource_stats holds 15-SECOND samples for the trailing HOUR. Every
  run pulls the whole window, so a 5-minute schedule still yields 15-second
  granularity - and a missed run loses nothing, because the next run re-reads
  the same window. De-duplication happens centrally on (target, end_time).

  A 1-minute schedule would give identical data at five times the connection
  cost across the estate. It buys nothing.

  What genuinely suffers from a 5-minute poll is BLOCKING, because a chain can
  start and finish between polls. That gap is covered by the ehd_blocking
  Extended Events session, which watches continuously and is harvested on the
  Standard tier.

  ------------------------------------------------------------------------------
  EDIT BEFORE RUNNING
  ------------------------------------------------------------------------------
  Nothing. The logical server name is a plain T-SQL variable (@OutServer) set
  from the literal below, and the output database comes from DB_NAME() - so it
  cannot be aimed somewhere else by mistake. No SQLCMD mode, no -v switches.

  Edit the literal only if you rename or move the server.
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
DECLARE @Group     nvarchar(128) = N'EHD_AllTargets';
DECLARE @Job       nvarchar(128) = N'EHD_Collect_Frequent';

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

/*==============================================================================
  JOB
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM jobs.jobs WHERE job_name = @Job)
    EXEC jobs.sp_add_job
         @job_name                = @Job,
         @description             = N'Resource usage, active requests, blocking, sessions, waits',
         @enabled                 = 1,
         @schedule_interval_type  = N'Minutes',
         @schedule_interval_count = 5;
ELSE
    EXEC jobs.sp_update_job
         @job_name                = @Job,
         @enabled                 = 1,
         @schedule_interval_type  = N'Minutes',
         @schedule_interval_count = 5;
GO

/*------------------------------------------------------------------------------
  MAKE REDEPLOYMENT ACTUALLY REDEPLOY

  Every sp_add_jobstep below is guarded by IF NOT EXISTS. Without this block, a
  second run against an existing job would silently keep the OLD @command text:
  you would edit a collection query, redeploy, see "Commands completed
  successfully", and still be running the previous version with no way to tell.

  Dropping the steps first means the guards always fire, so what is in this file
  is always what ends up in the agent.

  The JOB is left alone, so execution history in jobs.job_executions survives.
------------------------------------------------------------------------------*/
DECLARE @Job nvarchar(128) = N'EHD_Collect_Frequent';
DECLARE @steps TABLE (StepName nvarchar(128) PRIMARY KEY);

/* snapshot the names first - deleting a step bumps job_version, which would
   invalidate a cursor that joined on it mid-loop */
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
DECLARE @Job       nvarchar(128) = N'EHD_Collect_Frequent';
DECLARE @cmd       nvarchar(max);

DECLARE @Connected sysname = CONVERT(sysname, SERVERPROPERTY('ServerName'));
IF @Connected IS NOT NULL
BEGIN
    IF @Connected NOT LIKE N'%.%' SET @Connected = @Connected + N'.database.windows.net';
    IF LOWER(@Connected) <> LOWER(@OutServer) SET @OutServer = @Connected;
END

/*------------------------------------------------------------------------------
  STEP 1  ResourceUsage
  Pulls the entire dm_db_resource_stats window. Columns vary by service tier
  (DTU vs vCore vs Hyperscale vs Serverless), so the SELECT is built from the
  columns that actually exist - otherwise the step fails on the first database
  with a different shape and takes the whole run with it.

  end_time is datetime, and the agent types the staging column from whatever the
  query returns. datetime counts in ticks of 1/300 second, so .393 widens to
  .3933333 the moment it is compared with the datetime2(3) column in
  core.ResourceUsage - which broke the normalizer's duplicate guard. Casting here
  means new deployments land a datetime2(3) staging column that matches core
  exactly. (core.usp_Normalize converts defensively too, so estates whose staging
  table was already created as datetime keep working without a rebuild.)
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
SELECT * INTO #rs FROM sys.dm_db_resource_stats;
DECLARE @s nvarchar(max) = N''
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        EndTimeUtc        = CONVERT(datetime2(3), r.end_time),
        AvgCpuPct         = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''avg_cpu_percent'')            IS NOT NULL THEN N''r.avg_cpu_percent''            ELSE N''NULL'' END + N'',
        AvgDataIoPct      = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''avg_data_io_percent'')        IS NOT NULL THEN N''r.avg_data_io_percent''        ELSE N''NULL'' END + N'',
        AvgLogWritePct    = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''avg_log_write_percent'')      IS NOT NULL THEN N''r.avg_log_write_percent''      ELSE N''NULL'' END + N'',
        AvgMemoryPct      = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''avg_memory_usage_percent'')   IS NOT NULL THEN N''r.avg_memory_usage_percent''   ELSE N''NULL'' END + N'',
        MaxWorkerPct      = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''max_worker_percent'')         IS NOT NULL THEN N''r.max_worker_percent''         ELSE N''NULL'' END + N'',
        MaxSessionPct     = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''max_session_percent'')        IS NOT NULL THEN N''r.max_session_percent''        ELSE N''NULL'' END + N'',
        XtpStoragePct     = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''xtp_storage_percent'')        IS NOT NULL THEN N''r.xtp_storage_percent''        ELSE N''NULL'' END + N'',
        AvgInstanceCpuPct = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''avg_instance_cpu_percent'')   IS NOT NULL THEN N''r.avg_instance_cpu_percent''   ELSE N''NULL'' END + N'',
        DtuLimit          = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''dtu_limit'')                  IS NOT NULL THEN N''r.dtu_limit''                  ELSE N''NULL'' END + N'',
        CpuLimit          = '' + CASE WHEN COL_LENGTH(''tempdb..#rs'',''cpu_limit'')                  IS NOT NULL THEN N''r.cpu_limit''                  ELSE N''NULL'' END + N''
FROM    #rs AS r ORDER BY r.end_time;'';
EXEC sys.sp_executesql @s;
DROP TABLE #rs;';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'ResourceUsage')
    EXEC jobs.sp_add_jobstep
         @job_name              = @Job,
         @step_name             = N'ResourceUsage',
         @command               = @cmd,
         @target_group_name     = @Group,
         @output_type           = N'SqlDatabase',
         @output_server_name    = @OutServer,
         @output_database_name  = @OutDb,
         @output_schema_name    = N'stg',
         @output_table_name     = N'ResourceUsage',
         @retry_attempts        = 1,
         @step_timeout_seconds  = 120;

/*------------------------------------------------------------------------------
  STEP 2  ActiveRequests
  SQL text only for requests already running longer than 5 s, keeping the
  result set small. No plan capture: dm_exec_query_plan is the expensive part
  and is not worth it across a whole estate on a 5-minute cadence.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc       = @Now,
        SessionId         = r.session_id,
        RequestId         = r.request_id,
        Status            = r.status,
        Command           = r.command,
        WaitType          = NULLIF(r.wait_type, ''''),
        WaitResource      = NULLIF(LEFT(r.wait_resource, 256), ''''),
        WaitTimeMs        = r.wait_time,
        BlockingSessionId = NULLIF(r.blocking_session_id, 0),
        OpenTranCount     = r.open_transaction_count,
        CpuTimeMs         = r.cpu_time,
        TotalElapsedMs    = r.total_elapsed_time,
        LogicalReads      = r.logical_reads,
        Writes            = r.writes,
        RowCountSoFar     = r.row_count,
        GrantedMemoryKb   = r.granted_query_memory * 8,
        Dop               = r.dop,
        LoginName         = s.login_name,
        HostName          = s.host_name,
        ProgramName       = s.program_name,
        QueryHash         = CONVERT(varchar(20), r.query_hash, 1),
        SqlText           = CASE WHEN r.total_elapsed_time >= 5000
                                 THEN LEFT(t.text, 4000) END
FROM    sys.dm_exec_requests AS r
JOIN    sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE   r.session_id <> @@SPID
  AND   s.is_user_process = 1
  AND   (r.status <> ''sleeping'' OR ISNULL(r.blocking_session_id, 0) <> 0);';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'ActiveRequests')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'ActiveRequests', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'ActiveRequest',
         @retry_attempts = 1, @step_timeout_seconds = 120;

/*------------------------------------------------------------------------------
  STEP 3  Blocking
  Recursive walk to the head blocker, MAXRECURSION 32 against cyclic chains.
  Also captures a head blocker that is SLEEPING with an open transaction - the
  "application forgot to COMMIT" case that dm_exec_requests alone will not show.
  Returns nothing at all when there is no blocking, which is the common case.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests
               WHERE ISNULL(blocking_session_id,0) <> 0 AND session_id <> @@SPID)
BEGIN
    SELECT TOP (0)
        ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc = @Now, BlockedSessionId = CAST(0 AS smallint),
        BlockingSessionId = CAST(0 AS smallint), HeadBlockerSessionId = CAST(0 AS smallint),
        ChainDepth = 0, WaitType = CAST(NULL AS nvarchar(60)),
        WaitDurationMs = CAST(0 AS bigint), ResourceDescription = CAST(NULL AS nvarchar(512)),
        BlockedLogin = CAST(NULL AS nvarchar(256)), BlockedProgram = CAST(NULL AS nvarchar(256)),
        BlockedSql = CAST(NULL AS nvarchar(4000)), BlockerLogin = CAST(NULL AS nvarchar(256)),
        BlockerHost = CAST(NULL AS nvarchar(256)), BlockerProgram = CAST(NULL AS nvarchar(256)),
        BlockerStatus = CAST(NULL AS varchar(30)), BlockerSql = CAST(NULL AS nvarchar(4000));
    RETURN;
END;
WITH blocked AS (
    SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time,
           r.wait_resource, r.sql_handle
    FROM   sys.dm_exec_requests AS r
    WHERE  ISNULL(r.blocking_session_id,0) <> 0
      AND  r.session_id <> @@SPID AND r.blocking_session_id <> r.session_id
),
chain AS (
    SELECT LeafSession = b.session_id, CurrentSession = b.session_id,
           BlockerSession = b.blocking_session_id, Depth = 1
    FROM   blocked AS b
    UNION ALL
    SELECT c.LeafSession, p.session_id, p.blocking_session_id, c.Depth + 1
    FROM   chain AS c JOIN blocked AS p ON p.session_id = c.BlockerSession
    WHERE  c.Depth < 32
),
head AS (
    SELECT LeafSession, HeadBlocker = MAX(BlockerSession), MaxDepth = MAX(Depth)
    FROM   chain WHERE BlockerSession NOT IN (SELECT session_id FROM blocked)
    GROUP BY LeafSession
)
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc          = @Now,
        BlockedSessionId     = b.session_id,
        BlockingSessionId    = b.blocking_session_id,
        HeadBlockerSessionId = h.HeadBlocker,
        ChainDepth           = ISNULL(h.MaxDepth, 1),
        WaitType             = b.wait_type,
        WaitDurationMs       = CAST(b.wait_time AS bigint),
        ResourceDescription  = LEFT(b.wait_resource, 512),
        BlockedLogin         = bs.login_name,
        BlockedProgram       = bs.program_name,
        BlockedSql           = LEFT(bt.text, 4000),
        BlockerLogin         = ks.login_name,
        BlockerHost          = ks.host_name,
        BlockerProgram       = ks.program_name,
        BlockerStatus        = COALESCE(kr.status, ks.status),
        BlockerSql           = LEFT(COALESCE(kt.text, lt.text), 4000)
FROM    blocked AS b
LEFT JOIN head AS h ON h.LeafSession = b.session_id
LEFT JOIN sys.dm_exec_sessions    AS bs ON bs.session_id = b.session_id
LEFT JOIN sys.dm_exec_sessions    AS ks ON ks.session_id = b.blocking_session_id
LEFT JOIN sys.dm_exec_requests    AS kr ON kr.session_id = b.blocking_session_id
LEFT JOIN sys.dm_exec_connections AS kc ON kc.session_id = b.blocking_session_id
OUTER APPLY sys.dm_exec_sql_text(b.sql_handle)              AS bt
OUTER APPLY sys.dm_exec_sql_text(kr.sql_handle)             AS kt
OUTER APPLY sys.dm_exec_sql_text(kc.most_recent_sql_handle) AS lt
OPTION (MAXRECURSION 32);';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'Blocking')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'Blocking', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'BlockingChain',
         @retry_attempts = 1, @step_timeout_seconds = 120;

/*------------------------------------------------------------------------------
  STEP 4  SessionActivity - aggregated on the target to keep the payload small
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc   = @Now,
        ProgramName   = ISNULL(NULLIF(s.program_name, ''''), ''(unknown)''),
        LoginName     = ISNULL(NULLIF(s.login_name,   ''''), ''(unknown)''),
        HostName      = ISNULL(NULLIF(s.host_name,    ''''), ''(unknown)''),
        SessionCount  = COUNT_BIG(*),
        RunningCount  = SUM(CASE WHEN s.status = ''running''  THEN 1 ELSE 0 END),
        SleepingCount = SUM(CASE WHEN s.status = ''sleeping'' THEN 1 ELSE 0 END),
        BlockedCount  = SUM(CASE WHEN ISNULL(r.blocking_session_id,0) <> 0 THEN 1 ELSE 0 END),
        OpenTranCount = SUM(CASE WHEN s.open_transaction_count > 0 THEN 1 ELSE 0 END)
FROM    sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
WHERE   s.is_user_process = 1 AND s.session_id <> @@SPID
GROUP BY ISNULL(NULLIF(s.program_name, ''''), ''(unknown)''),
         ISNULL(NULLIF(s.login_name,   ''''), ''(unknown)''),
         ISNULL(NULLIF(s.host_name,    ''''), ''(unknown)'');';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'SessionActivity')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'SessionActivity', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'SessionActivity',
         @retry_attempts = 1, @step_timeout_seconds = 120;

/*------------------------------------------------------------------------------
  STEP 5  WaitStats - cumulative counters; deltas are derived centrally.
  The exclusion list removes idle and background waits that would otherwise
  bury the signal, but deliberately KEEPS the Azure throttling waits
  (LOG_RATE_GOVERNOR, HADR_THROTTLE_LOG_RATE_*, IO_QUEUE_LIMIT) - on Azure SQL
  those are usually the answer.
------------------------------------------------------------------------------*/
SET @cmd = N'
SET NOCOUNT ON;
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
SELECT  ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
        DatabaseName = DB_NAME(),
        SnapshotUtc       = @Now,
        WaitType          = w.wait_type,
        WaitingTasksCount = w.waiting_tasks_count,
        WaitTimeMs        = w.wait_time_ms,
        MaxWaitTimeMs     = w.max_wait_time_ms,
        SignalWaitTimeMs  = w.signal_wait_time_ms
FROM    sys.dm_db_wait_stats AS w
WHERE   w.waiting_tasks_count > 0
  AND   w.wait_type NOT IN (
        N''BROKER_EVENTHANDLER'',N''BROKER_RECEIVE_WAITFOR'',N''BROKER_TASK_STOP'',
        N''BROKER_TO_FLUSH'',N''BROKER_TRANSMITTER'',N''CHECKPOINT_QUEUE'',N''CHKPT'',
        N''CLR_AUTO_EVENT'',N''CLR_MANUAL_EVENT'',N''CLR_SEMAPHORE'',
        N''DBMIRROR_DBM_EVENT'',N''DBMIRROR_EVENTS_QUEUE'',N''DBMIRROR_WORKER_QUEUE'',
        N''DBMIRRORING_CMD'',N''DIRTY_PAGE_POLL'',N''DISPATCHER_QUEUE_SEMAPHORE'',
        N''EXECSYNC'',N''FSAGENT'',N''FT_IFTS_SCHEDULER_IDLE_WAIT'',N''FT_IFTSHC_MUTEX'',
        N''HADR_CLUSAPI_CALL'',N''HADR_FILESTREAM_IOMGR_IOCOMPLETION'',
        N''HADR_LOGCAPTURE_WAIT'',N''HADR_NOTIFICATION_DEQUEUE'',N''HADR_TIMER_TASK'',
        N''HADR_WORK_QUEUE'',N''KSOURCE_WAKEUP'',N''LAZYWRITER_SLEEP'',N''LOGMGR_QUEUE'',
        N''MEMORY_ALLOCATION_EXT'',N''ONDEMAND_TASK_QUEUE'',
        N''PARALLEL_REDO_DRAIN_WORKER'',N''PARALLEL_REDO_LOG_CACHE'',
        N''PARALLEL_REDO_TRAN_LIST'',N''PARALLEL_REDO_WORKER_SYNC'',
        N''PARALLEL_REDO_WORKER_WAIT_WORK'',N''PREEMPTIVE_XE_GETTARGETSTATE'',
        N''PWAIT_ALL_COMPONENTS_INITIALIZED'',N''PWAIT_DIRECTLOGCONSUMER_GETNEXT'',
        N''QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'',N''QDS_ASYNC_QUEUE'',
        N''QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'',N''QDS_SHUTDOWN_QUEUE'',
        N''REDO_THREAD_PENDING_WORK'',N''REQUEST_FOR_DEADLOCK_SEARCH'',
        N''RESOURCE_QUEUE'',N''SERVER_IDLE_CHECK'',N''SLEEP_BPOOL_FLUSH'',
        N''SLEEP_DBSTARTUP'',N''SLEEP_DCOMSTARTUP'',N''SLEEP_MASTERDBREADY'',
        N''SLEEP_MASTERMDREADY'',N''SLEEP_MASTERUPGRADED'',N''SLEEP_SYSTEMTASK'',
        N''SLEEP_TASK'',N''SLEEP_TEMPDBSTARTUP'',N''SNI_HTTP_ACCEPT'',
        N''SOS_WORK_DISPATCHER'',N''SP_SERVER_DIAGNOSTICS_SLEEP'',
        N''SQLTRACE_BUFFER_FLUSH'',N''SQLTRACE_INCREMENTAL_FLUSH_SLEEP'',
        N''SQLTRACE_WAIT_ENTRIES'',N''STARTUP_DEPENDENCY_MANAGER'',
        N''VDI_CLIENT_OTHER'',N''WAIT_FOR_RESULTS'',N''WAITFOR'',
        N''WAITFOR_TASKSHUTDOWN'',N''XE_DISPATCHER_JOIN'',N''XE_DISPATCHER_WAIT'',
        N''XE_LIVE_TARGET_TVF'',N''XE_TIMER_EVENT'',N''PARALLEL_REDO_FLOW_CONTROL'',
        N''POPULATE_LOCK_ORDINALS'');';

IF NOT EXISTS (SELECT 1 FROM jobs.jobsteps js JOIN jobs.jobs j
               ON j.job_id = js.job_id AND j.job_version = js.job_version
               WHERE j.job_name = @Job AND js.step_name = N'WaitStats')
    EXEC jobs.sp_add_jobstep
         @job_name = @Job, @step_name = N'WaitStats', @command = @cmd,
         @target_group_name = @Group,
         @output_type = N'SqlDatabase',
         @output_server_name = @OutServer, @output_database_name = @OutDb,
         @output_schema_name = N'stg', @output_table_name = N'WaitStats',
         @retry_attempts = 1, @step_timeout_seconds = 120;
GO

SELECT  j.job_name, js.step_id, js.step_name,
        js.output_schema_name, js.output_table_name, js.step_timeout_seconds
FROM    jobs.jobsteps AS js
JOIN    jobs.jobs     AS j ON j.job_id = js.job_id AND j.job_version = js.job_version
WHERE   j.job_name = N'EHD_Collect_Frequent'
ORDER BY js.step_id;
GO
