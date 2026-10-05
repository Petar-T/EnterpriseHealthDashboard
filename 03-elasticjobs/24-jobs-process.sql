/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 03-elasticjobs/24-jobs-process.sql
  Run in : THE database (Elastic Job Agent + central repository)

  Everything up to now COLLECTS. This file PROCESSES.

  The distinction matters because the two halves fail differently:

      collection jobs  -> target a group of many databases, run read-only,
                          failure of one target must not stop the others
      processing jobs  -> target exactly ONE database (the central repository),
                          run read-write, and are strictly ordered

  Why use Elastic Jobs for this at all, when the work happens inside the central
  database? Because Azure SQL Database has no SQL Agent. Something outside the
  database has to pull the trigger, and you already have a job agent running.
  Using it for both halves means one place to look when something stops.

  ORDERING. The three steps must run in sequence:

      1. Normalize  - staging -> core. Nothing downstream is valid until this
                      has run, because the views read core, not stg.
      2. Alerts     - evaluates the rules over freshly normalized data.
      3. Purge      - runs LAST and only in the daily job. Deleting rows that
                      the alert engine is about to read would be pointless work
                      at best and a source of flapping alerts at worst.

  Elastic Jobs runs steps in step_id order and, by default, STOPS the job if a
  step fails after exhausting its retries. That is the behaviour we want here:
  if normalization failed, evaluating alerts over half-loaded data is worse
  than not evaluating them at all.

  SINGLE DATABASE. The Job Agent database and the repository are the same
  database, so this job targets itself. That is legal - a job agent database is
  an ordinary Azure SQL Database and can be a target like any other - and it is
  why the database name below comes from DB_NAME() rather than a parameter.
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
  Plain T-SQL variable - no SQLCMD mode, no -v switches. The repository IS this
  database, so the server is by definition the one you are connected to. The
  literal documents intent; the live connection is the authority.
------------------------------------------------------------------------------*/
DECLARE @CentralServer nvarchar(256) = N'ehd-server.database.windows.net';   -- EDIT HERE if the server is renamed or moved

DECLARE @Connected sysname = CONVERT(sysname, SERVERPROPERTY('ServerName'));
IF @Connected IS NOT NULL
BEGIN
    IF @Connected NOT LIKE N'%.%' SET @Connected = @Connected + N'.database.windows.net';
    IF LOWER(@Connected) <> LOWER(@CentralServer)
    BEGIN
        PRINT N'NOTE: literal @CentralServer (' + @CentralServer + N') differs from this connection - using ' + @Connected + N'.';
        SET @CentralServer = @Connected;
    END
END
PRINT N'Central target  : ' + @CentralServer + N' / ' + DB_NAME();
GO

/*==============================================================================
  TARGET GROUP - exactly one member: this database.

  Kept separate from the collection groups on purpose. If this database ever
  ended up in a collection group by accident, the read-only collection queries
  would run against it too. Harmless, but it would add a row to the fleet
  scorecard for the monitoring database itself, which is noise. Disjoint groups
  make that mistake visible.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM jobs.target_groups WHERE target_group_name = N'EHD_Central')
    EXEC jobs.sp_add_target_group @target_group_name = N'EHD_Central';
GO

/* Repeated because T-SQL variables do not survive a GO. Same rule: literal
   documents intent, live connection is the authority. */
DECLARE @CentralServer   nvarchar(256) = N'ehd-server.database.windows.net';   -- EDIT HERE too if the server is renamed or moved
DECLARE @CentralDatabase nvarchar(128) = DB_NAME();

DECLARE @Connected sysname = CONVERT(sysname, SERVERPROPERTY('ServerName'));
IF @Connected IS NOT NULL
BEGIN
    IF @Connected NOT LIKE N'%.%' SET @Connected = @Connected + N'.database.windows.net';
    IF LOWER(@Connected) <> LOWER(@CentralServer) SET @CentralServer = @Connected;
END

IF NOT EXISTS (SELECT 1
               FROM   jobs.target_group_members m
               JOIN   jobs.target_groups g ON g.target_group_id = m.target_group_id
               WHERE  g.target_group_name = N'EHD_Central'
                 AND  m.target_type       = N'SqlDatabase'
                 AND  m.database_name     = @CentralDatabase)
    EXEC jobs.sp_add_target_group_member
         @target_group_name = N'EHD_Central',
         @membership_type   = N'Include',
         @target_type       = N'SqlDatabase',
         @server_name       = @CentralServer,
         @database_name     = @CentralDatabase;
GO


/*==============================================================================
  JOB 1 : EHD_Process_Frequent   - every 5 minutes, offset behind collection

  Runs normalize then alerts. Nothing else.

  THE OFFSET MATTERS. Collection runs every 5 minutes. If processing also runs
  every 5 minutes starting at the same instant, it races the collection it is
  meant to consume and will regularly normalize a half-written staging table.

  Elastic Jobs has no "run 2 minutes after job X" primitive, so we shift the
  schedule start time by 2 minutes instead. Collection at :00, :05, :10 ...
  processing at :02, :07, :12 ... Because staging rows are consumed by
  timestamp and purged only after 48 hours, anything the race does miss is
  picked up by the NEXT pass rather than lost.
==============================================================================*/
IF EXISTS (SELECT 1 FROM jobs.jobs WHERE job_name = N'EHD_Process_Frequent')
    EXEC jobs.sp_delete_job @job_name = N'EHD_Process_Frequent', @force = 1;
GO

EXEC jobs.sp_add_job
     @job_name    = N'EHD_Process_Frequent',
     @description = N'Enterprise Health Dashboard: staging -> core, then evaluate alerts. Runs in the central repository only.',
     @enabled     = 1,
     @schedule_interval_type  = N'Minutes',
     @schedule_interval_count = 5,
     /* 2-minute offset so this trails the collection jobs instead of racing them.
        The date part is arbitrary and in the past - only the time-of-day and the
        interval are used. */
     @schedule_start_time     = '2024-01-01T00:02:00';
GO

/*-- step 1 : normalize ------------------------------------------------------
  @retry_attempts is 2 rather than the collection default because a transient
  failure here delays EVERY downstream consumer, not just one database's feed.
  usp_Normalize is idempotent - each feed uses a MERGE or a NOT EXISTS guard -
  so re-running after a partial failure is safe.
---------------------------------------------------------------------------*/
EXEC jobs.sp_add_jobstep
     @job_name         = N'EHD_Process_Frequent',
     @step_name        = N'01_Normalize',
     @command          = N'EXEC core.usp_Normalize;',
     @target_group_name= N'EHD_Central',
     @retry_attempts   = 2,
     @initial_retry_interval_seconds = 10,
     @step_timeout_seconds = 600;
GO

/*-- step 2 : evaluate alerts ------------------------------------------------
  Deliberately AFTER normalize. usp_EvaluateAlerts loops over every enabled
  target, traps errors per target, and auto-resolves alerts that no longer
  apply. It writes only to core.AlertHistory and core.ProcessRun.
---------------------------------------------------------------------------*/
EXEC jobs.sp_add_jobstep
     @job_name         = N'EHD_Process_Frequent',
     @step_name        = N'02_EvaluateAlerts',
     @command          = N'EXEC core.usp_EvaluateAlerts;',
     @target_group_name= N'EHD_Central',
     @retry_attempts   = 1,
     @initial_retry_interval_seconds = 15,
     @step_timeout_seconds = 600;
GO


/*==============================================================================
  JOB 2 : EHD_Process_Daily   - once a day, off-hours

  Purge is the only thing in here. It is separated from the frequent job for
  three reasons:

    1. It deletes millions of rows. Running that every 5 minutes would keep the
       central database permanently busy doing nothing useful.
    2. It must never run BEFORE alert evaluation in the same pass.
    3. If it fails, alerts must keep working. Separate job = separate failure.

  03:15 UTC is chosen to sit after the daily COLLECTION job (which runs at
  03:00 in 23-jobs-daily.sql) so the daily feeds have landed and been
  normalized before old rows are trimmed.
==============================================================================*/
IF EXISTS (SELECT 1 FROM jobs.jobs WHERE job_name = N'EHD_Process_Daily')
    EXEC jobs.sp_delete_job @job_name = N'EHD_Process_Daily', @force = 1;
GO

EXEC jobs.sp_add_job
     @job_name    = N'EHD_Process_Daily',
     @description = N'Enterprise Health Dashboard: retention. Deletes aged rows from core and stg per cfg.Setting Retention.* values.',
     @enabled     = 1,
     @schedule_interval_type  = N'Hours',
     @schedule_interval_count = 24,
     @schedule_start_time     = '2024-01-01T03:15:00';
GO

/*-- step 1 : normalize once more --------------------------------------------
  Belt and braces. The daily COLLECTION job lands index, security and table
  space feeds at 03:00. The frequent processing job will normalize them within
  five minutes anyway, but running it explicitly here removes the dependency on
  that timing and guarantees the daily feeds are in core BEFORE purge decides
  what is old.
---------------------------------------------------------------------------*/
EXEC jobs.sp_add_jobstep
     @job_name         = N'EHD_Process_Daily',
     @step_name        = N'01_Normalize',
     @command          = N'EXEC core.usp_Normalize;',
     @target_group_name= N'EHD_Central',
     @retry_attempts   = 2,
     @initial_retry_interval_seconds = 30,
     @step_timeout_seconds = 1800;
GO

/*-- step 2 : purge ----------------------------------------------------------
  Long timeout: on a large estate the first real purge after a retention change
  can move tens of millions of rows. usp_Purge batches internally and has a
  1000-batch runaway guard, so if it does not finish in one pass it stops
  cleanly and the next night continues where it left off.
---------------------------------------------------------------------------*/
EXEC jobs.sp_add_jobstep
     @job_name         = N'EHD_Process_Daily',
     @step_name        = N'02_Purge',
     @command          = N'EXEC core.usp_Purge @DryRun = 0;',
     @target_group_name= N'EHD_Central',
     @retry_attempts   = 0,          -- a half-finished purge resumes tomorrow; retrying now just fights the same rows
     @initial_retry_interval_seconds = 60,
     @step_timeout_seconds = 3600;
GO

/*-- step 3 : refresh the target registry ------------------------------------
  Any database that has reported data but is not in cfg.Target gets added
  automatically, and LastSeenUtc is refreshed for the rest. Without this,
  a database added to a collection target group would send data that the
  fleet scorecard never shows, because the scorecard is driven by cfg.Target.
---------------------------------------------------------------------------*/
EXEC jobs.sp_add_jobstep
     @job_name         = N'EHD_Process_Daily',
     @step_name        = N'03_SyncTargetRegistry',
     @command          = N'
        /* refresh last-seen for known targets */
        UPDATE t
           SET LastSeenUtc = a.LastArrivalUtc
        FROM   cfg.Target AS t
        CROSS APPLY (SELECT LastArrivalUtc = MAX(f.LastArrivalUtc)
                     FROM   core.FeedArrival AS f
                     WHERE  f.ServerName = t.ServerName
                       AND  f.DatabaseName = t.DatabaseName) AS a
        WHERE  a.LastArrivalUtc IS NOT NULL
          AND (t.LastSeenUtc IS NULL OR a.LastArrivalUtc > t.LastSeenUtc);

        /* auto-register anything that is reporting but unknown */
        INSERT cfg.Target (ServerName, DatabaseName, Environment, Criticality, IsVendorOwned, IsEnabled, Notes)
        SELECT DISTINCT f.ServerName, f.DatabaseName, N''Unclassified'', N''Medium'', 1, 1,
               N''Auto-registered by EHD_Process_Daily - set Environment, Owner and Criticality.''
        FROM   core.FeedArrival AS f
        WHERE  NOT EXISTS (SELECT 1 FROM cfg.Target t
                           WHERE t.ServerName = f.ServerName
                             AND t.DatabaseName = f.DatabaseName);',
     @target_group_name= N'EHD_Central',
     @retry_attempts   = 1,
     @step_timeout_seconds = 300;
GO


PRINT '';
PRINT '=====================================================================';
PRINT ' PROCESSING JOBS CREATED';
PRINT '=====================================================================';
PRINT ' EHD_Process_Frequent   every 5 min, offset +2 min';
PRINT '     01_Normalize           stg -> core';
PRINT '     02_EvaluateAlerts      raise / auto-resolve';
PRINT '';
PRINT ' EHD_Process_Daily      daily at 03:15 UTC';
PRINT '     01_Normalize           catch the 03:00 daily feeds';
PRINT '     02_Purge               enforce Retention.* settings';
PRINT '     03_SyncTargetRegistry  auto-register new databases';
PRINT '';
PRINT ' Watch them:';
PRINT '   SELECT TOP 50 * FROM jobs.job_executions';
PRINT '   WHERE job_name LIKE ''EHD_Process%'' ORDER BY start_time DESC;';
PRINT '';
PRINT ' First run is manual - do not wait 5 minutes to find a typo:';
PRINT '   EXEC jobs.sp_start_job ''EHD_Process_Frequent'';';
PRINT '';
PRINT ' Preview retention BEFORE the daily job fires for the first time:';
PRINT '   EXEC core.usp_Purge @DryRun = 1;';
PRINT '=====================================================================';
GO

SET NOEXEC OFF;
GO
