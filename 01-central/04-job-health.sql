/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 01-central/04-job-health.sql
  Run in : THE database (agent + repository)

  ------------------------------------------------------------------------------
  WHY THIS FILE EXISTS
  ------------------------------------------------------------------------------
  core.FeedArrival answers "when did data last arrive from this database?".
  It cannot answer "and if it didn't, WHY not?" - that lives in
  jobs.job_executions, which the Elastic Job Agent maintains.

  When the agent and the repository were separate databases, joining those two
  facts meant two connections to two databases, because Azure SQL Database has
  no cross-database queries. The dashboard simply could not show a failure
  reason, and its "Fails 24h" column was hard-coded to zero.

  In the single-database design they are two schemas in one database, so the
  join is ordinary SQL. This file is the entire benefit of that decision, made
  concrete.

  ------------------------------------------------------------------------------
  DEPLOYMENT ORDER PROBLEM, AND HOW IT IS HANDLED
  ------------------------------------------------------------------------------
  The [jobs] schema does not exist until the Elastic Job Agent has been created
  and pointed at this database. But you will usually deploy 01-central\*.sql
  BEFORE creating the agent, because Microsoft's guidance is to point an agent
  at a database that is otherwise clean of agent objects.

  A plain CREATE VIEW referencing jobs.job_executions would therefore fail on a
  first deployment. So each view is created through dynamic SQL: the real
  definition when the agent schema is present, an empty stub with an identical
  column list when it is not.

  The stub is not a failure mode - every consumer keeps working and simply sees
  no job history. Re-running this file after the agent exists upgrades the views
  in place. Deploy-Enterprise.ps1 re-runs it for exactly that reason.
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

DECLARE @HasAgent bit =
    CASE WHEN OBJECT_ID('jobs.job_executions') IS NOT NULL THEN 1 ELSE 0 END;

IF @HasAgent = 0
    PRINT '!! jobs.job_executions not found - creating EMPTY STUB views. Re-run this file after the Elastic Job Agent has been created against this database.';
ELSE
    PRINT 'jobs schema found - creating live job-health views.';

/*------------------------------------------------------------------------------
  core.vw_JobExecution
  One row per job step execution against one target, newest first.

  jobs.job_executions holds both job-level rows (step_id IS NULL) and step-level
  rows. Only step-level rows carry target_server_name / target_database_name,
  and only those are useful for attributing a failure to a database, so the
  job-level rows are filtered out.

  JobTier maps the job name onto the collection tier the rest of the system
  uses, so this view joins cleanly to core.FeedArrival.
------------------------------------------------------------------------------*/
DECLARE @sql nvarchar(max);

SET @sql = CASE WHEN @HasAgent = 1 THEN N'
CREATE OR ALTER VIEW core.vw_JobExecution
AS
SELECT  JobName        = e.job_name,
        StepName       = e.step_name,
        JobTier        = CASE
                            WHEN e.job_name LIKE ''%Collect_Frequent%'' THEN ''Frequent''
                            WHEN e.job_name LIKE ''%Collect_Standard%'' THEN ''Standard''
                            WHEN e.job_name LIKE ''%Collect_Daily%''    THEN ''Daily''
                            WHEN e.job_name LIKE ''%Process%''          THEN ''Processing''
                            WHEN e.job_name LIKE ''%Setup%''            THEN ''Setup''
                            ELSE ''Other'' END,
        ServerName     = e.target_server_name,
        DatabaseName   = e.target_database_name,
        Lifecycle      = e.lifecycle,
        IsFailure      = CASE WHEN e.lifecycle IN (''Failed'',''TimedOut'',''Canceled'') THEN 1 ELSE 0 END,
        IsSuccess      = CASE WHEN e.lifecycle IN (''Succeeded'',''SucceededWithSkipped'') THEN 1 ELSE 0 END,
        StartTimeUtc   = e.start_time,
        EndTimeUtc     = e.end_time,
        DurationSec    = DATEDIFF(SECOND, e.start_time, e.end_time),
        Attempts       = e.current_attempts,
        LastMessage    = e.last_message,
        AgeMinutes     = DATEDIFF(MINUTE, e.start_time, SYSUTCDATETIME())
FROM    jobs.job_executions AS e
WHERE   e.step_id IS NOT NULL
  AND   e.job_name LIKE ''EHD[_]%'';'
ELSE N'
CREATE OR ALTER VIEW core.vw_JobExecution
AS
SELECT  JobName = CAST(NULL AS nvarchar(128)),
        StepName= CAST(NULL AS nvarchar(128)),
        JobTier = CAST(NULL AS varchar(20)),
        ServerName   = CAST(NULL AS nvarchar(256)),
        DatabaseName = CAST(NULL AS nvarchar(128)),
        Lifecycle    = CAST(NULL AS nvarchar(50)),
        IsFailure    = CAST(0 AS int),
        IsSuccess    = CAST(0 AS int),
        StartTimeUtc = CAST(NULL AS datetime2(3)),
        EndTimeUtc   = CAST(NULL AS datetime2(3)),
        DurationSec  = CAST(NULL AS int),
        Attempts     = CAST(NULL AS int),
        LastMessage  = CAST(NULL AS nvarchar(max)),
        AgeMinutes   = CAST(NULL AS int)
WHERE   1 = 0;' END;

EXEC sys.sp_executesql @sql;
GO


/*------------------------------------------------------------------------------
  core.vw_JobHealth
  One row per (database, tier) over the last 24 hours. This is what the
  dashboard's collection pipeline table reads.

  Deliberately built on core.vw_JobExecution rather than on jobs.job_executions
  directly, so the stub keeps this view valid before the agent exists.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_JobHealth
AS
SELECT  ServerName, DatabaseName, JobTier,
        Attempts24h   = COUNT(*),
        Failures24h   = SUM(IsFailure),
        Successes24h  = SUM(IsSuccess),
        LastSuccessUtc= MAX(CASE WHEN IsSuccess = 1 THEN StartTimeUtc END),
        LastFailureUtc= MAX(CASE WHEN IsFailure = 1 THEN StartTimeUtc END),
        FailurePct    = CAST(SUM(IsFailure) * 100.0 / NULLIF(COUNT(*), 0) AS decimal(9,2)),
        /* the actual reason, which is the whole point of consolidating */
        LastError     = MAX(CASE WHEN IsFailure = 1 THEN LEFT(LastMessage, 500) END),
        MaxDurationSec= MAX(DurationSec)
FROM    core.vw_JobExecution
WHERE   StartTimeUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
  AND   ServerName IS NOT NULL
GROUP BY ServerName, DatabaseName, JobTier;
GO


/*------------------------------------------------------------------------------
  core.vw_FeedDiagnosis
  The join that used to be impossible: feed freshness NEXT TO the job outcome
  that explains it.

  Diagnosis is the column worth reading. "Feed is stale" is an observation;
  "feed is stale AND the job is failing with 'Login failed for user' " is an
  answer.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_FeedDiagnosis
AS
WITH feed AS
(
    SELECT  ServerName, DatabaseName, Tier,
            LastArrivalUtc = MAX(LastArrivalUtc),
            AgeMin         = DATEDIFF(MINUTE, MAX(LastArrivalUtc), SYSUTCDATETIME()),
            FeedCount      = COUNT(*)
    FROM    core.FeedArrival
    GROUP BY ServerName, DatabaseName, Tier
)
SELECT  t.ServerName,
        t.DatabaseName,
        Tier      = ISNULL(f.Tier, j.JobTier),
        f.LastArrivalUtc,
        f.AgeMin,
        LimitMin  = CASE ISNULL(f.Tier, j.JobTier)
                        WHEN 'Frequent' THEN cfg.fn_Int('Stale.FrequentMinutes', 20)
                        WHEN 'Standard' THEN cfg.fn_Int('Stale.StandardMinutes', 90)
                        WHEN 'Daily'    THEN cfg.fn_Int('Stale.DailyMinutes', 1560)
                        ELSE NULL END,
        j.Attempts24h,
        j.Failures24h,
        j.LastSuccessUtc,
        j.LastFailureUtc,
        j.LastError,
        Diagnosis = CASE
            WHEN j.Attempts24h IS NULL AND f.LastArrivalUtc IS NULL
                THEN 'No job has run and no data has arrived - is this database in a target group?'
            WHEN j.Attempts24h IS NULL
                THEN 'Data arrived earlier but no job has run in 24 h - check the schedule or the agent'
            WHEN j.Failures24h = j.Attempts24h
                THEN 'EVERY run failed: ' + ISNULL(j.LastError, '(no message)')
            WHEN j.Failures24h > 0 AND f.AgeMin >
                 CASE ISNULL(f.Tier, j.JobTier)
                      WHEN 'Frequent' THEN cfg.fn_Int('Stale.FrequentMinutes', 20)
                      WHEN 'Standard' THEN cfg.fn_Int('Stale.StandardMinutes', 90)
                      WHEN 'Daily'    THEN cfg.fn_Int('Stale.DailyMinutes', 1560)
                      ELSE 2147483647 END
                THEN 'Stale and failing intermittently: ' + ISNULL(j.LastError, '(no message)')
            WHEN j.Failures24h > 0
                THEN 'Recovering - some runs failed but data is current'
            WHEN f.LastArrivalUtc IS NULL
                THEN 'Job succeeds but returns no rows - check permissions on the target'
            ELSE 'Healthy' END
FROM    cfg.Target AS t
LEFT JOIN feed AS f
       ON f.ServerName = t.ServerName AND f.DatabaseName = t.DatabaseName
LEFT JOIN core.vw_JobHealth AS j
       ON j.ServerName = t.ServerName AND j.DatabaseName = t.DatabaseName
      AND j.JobTier    = f.Tier
WHERE   t.IsEnabled = 1;
GO


/*------------------------------------------------------------------------------
  core.vw_JobRunSummary
  Agent-wide health, not per-database. Answers "is the pipeline itself ok?"
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_JobRunSummary
AS
SELECT  JobName,
        StepName,
        Runs24h      = COUNT(*),
        Failures24h  = SUM(IsFailure),
        FailurePct   = CAST(SUM(IsFailure) * 100.0 / NULLIF(COUNT(*), 0) AS decimal(9,2)),
        AvgDurationSec = CAST(AVG(CAST(DurationSec AS decimal(19,2))) AS decimal(19,2)),
        MaxDurationSec = MAX(DurationSec),
        LastRunUtc   = MAX(StartTimeUtc),
        LastError    = MAX(CASE WHEN IsFailure = 1 THEN LEFT(LastMessage, 500) END)
FROM    core.vw_JobExecution
WHERE   StartTimeUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY JobName, StepName;
GO

PRINT '=== job-health views deployed ===';
PRINT '  core.vw_JobExecution   raw step executions';
PRINT '  core.vw_JobHealth      per database + tier, 24 h';
PRINT '  core.vw_FeedDiagnosis  freshness joined to the reason it is stale';
PRINT '  core.vw_JobRunSummary  agent-wide job health';
GO
