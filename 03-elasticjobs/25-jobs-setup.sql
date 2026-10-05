/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 03-elasticjobs/25-jobs-setup.sql
  Run in : THE database (Elastic Job Agent + central repository)

  ------------------------------------------------------------------------------
  THIS IS THE ONE JOB THAT WRITES TO A TARGET. IT IS OPTIONAL.
  ------------------------------------------------------------------------------
  Every other job in this system is read-only, and tests\Test-EmbeddedCommands.ps1
  enforces that mechanically. This file is the deliberate, isolated exception:
  it deploys the two Extended Events sessions and configures Query Store on each
  target.

  It is kept in its OWN FILE precisely so the read-only guarantee stays provable
  for everything else. Test-EmbeddedCommands.ps1 skips this file by name, and
  says so in its output - a silent exemption would be worse than no exemption.

  WHAT IT CHANGES ON A TARGET
      2 Extended Events sessions, ring buffer only, no file target, no credential
      Query Store enabled and right-sized (usually already on)

  WHAT IT NEVER DOES
      no tables, no procedures, no schema changes, no data access

  SKIP THIS ENTIRELY and you still collect resource usage, waits, blocking,
  sessions, space, IO, query stats, indexes and security. You lose error events
  and deadlock graphs, and the Query Store feed if Query Store is off.

  ------------------------------------------------------------------------------
  CREATED DISABLED AND UNSCHEDULED, ON PURPOSE
  ------------------------------------------------------------------------------
  The job is created with @enabled = 0 and no recurring schedule. It will never
  run on its own. To apply it, start it by hand once the vendor or database
  owner has agreed:

      EXEC jobs.sp_start_job 'EHD_Setup_Targets';

  Both steps are idempotent, so running it repeatedly is harmless - and that is
  how a newly-added database gets configured: start the job again.
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

DECLARE @Job   nvarchar(128) = N'EHD_Setup_Targets';
DECLARE @Group nvarchar(128) = N'EHD_AllTargets';

IF EXISTS (SELECT 1 FROM jobs.jobs WHERE job_name = @Job)
    EXEC jobs.sp_delete_job @job_name = @Job, @force = 1;

EXEC jobs.sp_add_job
     @job_name    = @Job,
     @description = N'OPTIONAL. Deploys the 2 XE sessions and configures Query Store on each target. The only job that writes to a target. Disabled and unscheduled by design - start it manually.',
     @enabled     = 0;
GO


/*==============================================================================
  STEP 1 - Extended Events sessions

  Ring buffer only. A file target would need a DATABASE SCOPED CREDENTIAL in the
  target database, which is exactly the footprint this edition avoids. Durability
  comes from EHD_Collect_Standard harvesting the buffer every 30 minutes.

  Event availability differs by tier and engine version, so each event is probed
  with sys.dm_xe_objects before being included. A missing event degrades the
  session rather than failing the whole statement.
==============================================================================*/
DECLARE @Job nvarchar(128) = N'EHD_Setup_Targets';
DECLARE @Group nvarchar(128) = N'EHD_AllTargets';
DECLARE @cmd nvarchar(max);

SET @cmd = N'
SET NOCOUNT ON;

/*--- ehd_errors : error_reported, attention, deadlock graph ----------------*/
IF NOT EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N''ehd_errors'')
BEGIN
    DECLARE @ev nvarchar(max) = N'''';

    IF EXISTS (SELECT 1 FROM sys.dm_xe_objects WHERE name = ''error_reported'' AND object_type = ''event'')
        SET @ev += N''
        ADD EVENT sqlserver.error_reported(
            ACTION (sqlserver.session_id, sqlserver.username, sqlserver.client_app_name,
                    sqlserver.client_hostname, sqlserver.sql_text)
            WHERE  severity >= 11),'';

    IF EXISTS (SELECT 1 FROM sys.dm_xe_objects WHERE name = ''database_xml_deadlock_report'' AND object_type = ''event'')
        SET @ev += N''
        ADD EVENT sqlserver.database_xml_deadlock_report,'';

    IF @ev <> N''''
    BEGIN
        SET @ev = LEFT(@ev, LEN(@ev) - 1);   -- strip trailing comma
        DECLARE @sql nvarchar(max) = N''CREATE EVENT SESSION [ehd_errors] ON DATABASE'' + @ev + N''
            ADD TARGET package0.ring_buffer(SET max_memory = (4096), max_events_limit = (2000))
            WITH (MAX_MEMORY = 4096 KB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
                  MAX_DISPATCH_LATENCY = 30 SECONDS, STARTUP_STATE = ON);'';
        EXEC (@sql);
        EXEC (N''ALTER EVENT SESSION [ehd_errors] ON DATABASE STATE = START;'');
    END
END

/*--- ehd_blocking : long lock waits, reconstructed from sqlos.wait_info ----*/
IF NOT EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N''ehd_blocking'')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_xe_objects WHERE name = ''wait_info'' AND object_type = ''event'')
    BEGIN
        DECLARE @sql2 nvarchar(max) = N''
        CREATE EVENT SESSION [ehd_blocking] ON DATABASE
        ADD EVENT sqlos.wait_info(
            ACTION (sqlserver.session_id, sqlserver.username, sqlserver.client_app_name,
                    sqlserver.sql_text)
            WHERE  duration > 30000
              AND (wait_type = 66 OR wait_type = 67 OR wait_type = 68 OR wait_type = 69))
        ADD TARGET package0.ring_buffer(SET max_memory = (4096), max_events_limit = (2000))
        WITH (MAX_MEMORY = 4096 KB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
              MAX_DISPATCH_LATENCY = 30 SECONDS, STARTUP_STATE = ON);'';
        EXEC (@sql2);
        EXEC (N''ALTER EVENT SESSION [ehd_blocking] ON DATABASE STATE = START;'');
    END
END

/*--- report back so the run is observable ---------------------------------*/
SELECT SessionName = s.name,
       State       = CASE WHEN r.name IS NULL THEN ''STOPPED'' ELSE ''RUNNING'' END
FROM   sys.database_event_sessions AS s
LEFT JOIN sys.dm_xe_database_sessions AS r ON r.name = s.name
WHERE  s.name IN (N''ehd_errors'', N''ehd_blocking'');';

EXEC jobs.sp_add_jobstep
     @job_name          = @Job,
     @step_name         = N'01_XeSessions',
     @command           = @cmd,
     @target_group_name = @Group,
     @retry_attempts    = 1,
     @step_timeout_seconds = 300;
GO


/*==============================================================================
  STEP 2 - Query Store

  Enables it when off and right-sizes it. NEVER downgrades an existing
  configuration: if the database already has a larger store or a finer interval,
  those are left alone. Someone chose them deliberately.
==============================================================================*/
DECLARE @Job nvarchar(128) = N'EHD_Setup_Targets';
DECLARE @Group nvarchar(128) = N'EHD_AllTargets';

EXEC jobs.sp_add_jobstep
     @job_name          = @Job,
     @step_name         = N'02_QueryStore',
     @command           = N'
SET NOCOUNT ON;

DECLARE @state  tinyint = (SELECT actual_state FROM sys.database_query_store_options);
DECLARE @maxMB  bigint  = (SELECT max_storage_size_mb FROM sys.database_query_store_options);
DECLARE @ivl    bigint  = (SELECT interval_length_minutes FROM sys.database_query_store_options);

IF @state = 0
    ALTER DATABASE CURRENT SET QUERY_STORE = ON;

/* only ever increase the store, never shrink someone else''s choice */
IF ISNULL(@maxMB, 0) < 1024
    ALTER DATABASE CURRENT SET QUERY_STORE (MAX_STORAGE_SIZE_MB = 1024);

/* only coarsen if it is currently coarser than we need; never make it finer */
IF ISNULL(@ivl, 0) > 60 OR @ivl IS NULL
    ALTER DATABASE CURRENT SET QUERY_STORE (INTERVAL_LENGTH_MINUTES = 60);

ALTER DATABASE CURRENT SET QUERY_STORE (SIZE_BASED_CLEANUP_MODE = AUTO);
ALTER DATABASE CURRENT SET QUERY_STORE (QUERY_CAPTURE_MODE = AUTO);

SELECT ActualState       = actual_state_desc,
       MaxStorageMB      = max_storage_size_mb,
       IntervalMinutes   = interval_length_minutes,
       CurrentStorageMB  = current_storage_size_mb
FROM   sys.database_query_store_options;',
     @target_group_name = @Group,
     @retry_attempts    = 1,
     @step_timeout_seconds = 300;
GO


PRINT '';
PRINT '=====================================================================';
PRINT ' EHD_Setup_Targets created - DISABLED and UNSCHEDULED by design';
PRINT '=====================================================================';
PRINT '   01_XeSessions   2 ring-buffer sessions (error + blocking)';
PRINT '   02_QueryStore   enable and right-size, never downgrades';
PRINT '';
PRINT ' This is the ONLY job that writes to a target database. It will not';
PRINT ' run on its own. Apply it deliberately, once the database owner agrees:';
PRINT '';
PRINT '   EXEC jobs.sp_start_job ''EHD_Setup_Targets'';';
PRINT '';
PRINT ' Both steps are idempotent - re-run it to configure newly added';
PRINT ' databases. To remove the sessions again, see the removal block in';
PRINT ' 02-targets\11-target-xe-sessions.sql.';
PRINT '=====================================================================';
GO
