/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : tests/Test-CentralPipeline.sql
  Run in : a SCRATCH database that already has 01-central deployed
  Safe   : creates no permanent data - every row it inserts is removed at the end

  WHY THIS EXISTS
  ---------------
  Parsing a script proves it is syntactically valid. It does not prove that the
  alert engine fires, that de-duplication works, that auto-resolve works, or
  that the fleet views return anything at all. Those are behaviours, and
  behaviours need execution.

  This test injects a realistic estate into core.*, runs the engine, and asserts
  on the outcome. It is the only artifact in the project that exercises the
  system rather than inspecting it.

  It runs anywhere T-SQL runs - SQL Server 2017+ or Azure SQL Database - so it
  can be used to validate a build long before any Azure resources exist.

  WHAT IT ASSERTS
  ---------------
    1. a CPU breach raises CPU_CRITICAL
    2. a storage breach raises SPACE_CRITICAL
    3. a blocking breach raises BLOCKING_CRITICAL
    4. running the engine twice does NOT duplicate an open alert
    5. clearing the condition auto-resolves the alert
    6. core.vw_FleetScorecard returns the database with a degraded health score
    7. core.vw_CapacityForecast produces a bounded, sane projection
    8. a stale feed is reported as such by core.vw_TargetStatus

  USAGE
    sqlcmd -S <server> -d <scratch db> -i tests\Test-CentralPipeline.sql
==============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

DECLARE @S sysname = N'test-srv.database.windows.net';
DECLARE @D sysname = N'TestDb';
DECLARE @now datetime2(3) = SYSUTCDATETIME();
DECLARE @pass int = 0, @fail int = 0;

DECLARE @results TABLE (Seq int IDENTITY(1,1), Assertion nvarchar(200), Outcome varchar(6), Detail nvarchar(400));

/*------------------------------------------------------------------ clean up */
DELETE FROM core.AlertHistory   WHERE ServerName = @S;
DELETE FROM core.ResourceUsage  WHERE ServerName = @S;
DELETE FROM core.DatabaseSpace  WHERE ServerName = @S;
DELETE FROM core.BlockingChain  WHERE ServerName = @S;
DELETE FROM core.FeedArrival    WHERE ServerName = @S;
DELETE FROM cfg.Target          WHERE ServerName = @S;

/*----------------------------------------------------------- register target */
INSERT cfg.Target (ServerName, DatabaseName, Environment, Owner, Criticality, IsVendorOwned, IsEnabled)
VALUES (@S, @D, N'Test', N'pipeline-test', N'High', 1, 1);

/*--------------------------------------------------------------- fresh feeds
  Collection health is evaluated FIRST and short-circuits the resource rules,
  so the feeds must look healthy for this test to reach them at all.         */
INSERT core.FeedArrival (ServerName, DatabaseName, FeedName, Tier, LastArrivalUtc, LastRowCount)
VALUES (@S, @D, 'ResourceUsage', 'Frequent', DATEADD(MINUTE, -1, @now), 60),
       (@S, @D, 'WaitStats',     'Frequent', DATEADD(MINUTE, -1, @now), 40),
       (@S, @D, 'QueryStats',    'Standard', DATEADD(MINUTE, -5, @now), 25),
       (@S, @D, 'IndexUsage',    'Daily',    DATEADD(HOUR,  -2, @now), 80);

/*---------------------------------------------------------- breach: CPU 96%
  Averaged over the trailing 15 minutes, so a spread of samples is needed.   */
DECLARE @i int = 0;
WHILE @i < 15
BEGIN
    INSERT core.ResourceUsage (ServerName, DatabaseName, EndTimeUtc,
           AvgCpuPct, AvgDataIoPct, AvgLogWritePct, AvgMemoryPct, MaxWorkerPct, MaxSessionPct)
    VALUES (@S, @D, DATEADD(MINUTE, -@i, @now), 96.0, 20.0, 15.0, 70.0, 30.0, 25.0);
    SET @i += 1;
END

/*------------------------------------------------- breach: storage at 94.5%
  Also gives vw_CapacityForecast a growth slope to project from.             */
SET @i = 0;
WHILE @i < 30
BEGIN
    INSERT core.DatabaseSpace (ServerName, DatabaseName, SnapshotUtc,
           AllocatedMB, UsedMB, MaxSizeMB, PctOfMaxSize, ServiceObjective, Edition)
    VALUES (@S, @D, DATEADD(DAY, -29 + @i, @now),
            32768, 29000 + (@i * 32.0), 32768,
            (29000 + (@i * 32.0)) * 100.0 / 32768, N'GP_Gen5_2', N'GeneralPurpose');
    SET @i += 1;
END

/*------------------------------------------------- breach: 7-minute blocking */
INSERT core.BlockingChain (ServerName, DatabaseName, SnapshotUtc, BlockedSessionId,
       BlockingSessionId, HeadBlockerSessionId, ChainDepth, WaitType, WaitDurationMs,
       BlockerLogin, BlockerProgram, BlockerHost, BlockerStatus, BlockerSql, BlockedSql)
VALUES (@S, @D, DATEADD(MINUTE, -2, @now), 77, 55, 55, 1, N'LCK_M_X', 420000,
        N'svc_orders', N'OrderProcessor.exe', N'APPHOST01', N'sleeping',
        N'(idle - uncommitted transaction)', N'UPDATE dbo.Orders SET Status = 2 WHERE Id = 9');

/*============================================================== RUN THE ENGINE */
EXEC core.usp_EvaluateAlerts @ServerName = @S, @DatabaseName = @D;

/*------------------------------------------------------------- 1,2,3: raised */
INSERT @results (Assertion, Outcome, Detail)
SELECT '1. CPU_CRITICAL raised',
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('open rows = ', COUNT(*), '; ', MIN(Message))
FROM   core.AlertHistory
WHERE  ServerName = @S AND AlertCode = 'CPU_CRITICAL' AND ResolvedUtc IS NULL;

INSERT @results (Assertion, Outcome, Detail)
SELECT '2. SPACE_CRITICAL raised',
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('open rows = ', COUNT(*), '; ', MIN(Message))
FROM   core.AlertHistory
WHERE  ServerName = @S AND AlertCode = 'SPACE_CRITICAL' AND ResolvedUtc IS NULL;

INSERT @results (Assertion, Outcome, Detail)
SELECT '3. BLOCKING_CRITICAL raised',
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('open rows = ', COUNT(*), '; ', MIN(Message))
FROM   core.AlertHistory
WHERE  ServerName = @S AND AlertCode = 'BLOCKING_CRITICAL' AND ResolvedUtc IS NULL;

/*----------------------------------------------- 4: de-duplication on re-run
  The single most important property of the engine. A condition true for six
  hours must produce ONE row, not seventy-two.                               */
DECLARE @before int = (SELECT COUNT(*) FROM core.AlertHistory WHERE ServerName = @S);
EXEC core.usp_EvaluateAlerts @ServerName = @S, @DatabaseName = @D;
EXEC core.usp_EvaluateAlerts @ServerName = @S, @DatabaseName = @D;
DECLARE @after int = (SELECT COUNT(*) FROM core.AlertHistory WHERE ServerName = @S);

INSERT @results (Assertion, Outcome, Detail)
VALUES ('4. Re-running does not duplicate alerts',
        CASE WHEN @before = @after THEN 'PASS' ELSE 'FAIL' END,
        CONCAT('rows before = ', @before, ', after 2 more passes = ', @after));

/*------------------------------------------------------ 6: fleet scorecard
  Checked before the data is removed.                                        */
INSERT @results (Assertion, Outcome, Detail)
SELECT '6. vw_FleetScorecard reports the database as degraded',
       CASE WHEN COUNT(*) = 1 AND MIN(HealthScore) = 0 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('rows = ', COUNT(*), ', health = ', MIN(HealthScore),
              ', worst = ', MIN(WorstDimension), ', cpu = ', MIN(AvgCpuPct))
FROM   core.vw_FleetScorecard
WHERE  ServerName = @S;

/*--------------------------------------------------- 7: capacity projection
  Must be a real bounded number, never the overflow nonsense the embedded
  edition once produced.                                                      */
INSERT @results (Assertion, Outcome, Detail)
SELECT '7. vw_CapacityForecast gives a bounded projection',
       CASE WHEN COUNT(*) = 1
             AND MIN(DaysUntilFull) IS NOT NULL
             AND MIN(DaysUntilFull) BETWEEN 0 AND 3650 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('days = ', ISNULL(CONVERT(varchar(20), MIN(DaysUntilFull)), 'NULL'),
              ', verdict = ', MIN(Verdict), ', confidence = ', MIN(Confidence))
FROM   core.vw_CapacityForecast
WHERE  ServerName = @S;

/*----------------------------------------------------------- 8: stale feeds */
UPDATE core.FeedArrival
   SET LastArrivalUtc = DATEADD(HOUR, -6, @now)
 WHERE ServerName = @S AND Tier = 'Frequent';

INSERT @results (Assertion, Outcome, Detail)
SELECT '8. vw_TargetStatus detects a stale frequent tier',
       CASE WHEN MIN(CollectionState) = 'CRITICAL' THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('state = ', MIN(CollectionState), ', stale tiers = ', MIN(StaleTiers))
FROM   core.vw_TargetStatus
WHERE  ServerName = @S;

/*--------------------------------------------- 5: auto-resolve when cleared
  Remove every breach, restore fresh feeds, re-evaluate. Open alerts must
  close by themselves - nobody acknowledges anything in this system.         */
DELETE FROM core.ResourceUsage WHERE ServerName = @S;
DELETE FROM core.DatabaseSpace WHERE ServerName = @S;
DELETE FROM core.BlockingChain WHERE ServerName = @S;
UPDATE core.FeedArrival SET LastArrivalUtc = DATEADD(MINUTE, -1, @now) WHERE ServerName = @S;

EXEC core.usp_EvaluateAlerts @ServerName = @S, @DatabaseName = @D;

INSERT @results (Assertion, Outcome, Detail)
SELECT '5. Alerts auto-resolve once the condition clears',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('still open = ', COUNT(*),
              ISNULL(' (' + MIN(AlertCode) + ')', ''))
FROM   core.AlertHistory
WHERE  ServerName = @S AND ResolvedUtc IS NULL;

/*-------------------------------------------------------------------- report */
SELECT Seq, Assertion, Outcome, Detail FROM @results ORDER BY Seq;

SELECT Passed = SUM(CASE WHEN Outcome = 'PASS' THEN 1 ELSE 0 END),
       Failed = SUM(CASE WHEN Outcome = 'FAIL' THEN 1 ELSE 0 END),
       Verdict= CASE WHEN SUM(CASE WHEN Outcome = 'FAIL' THEN 1 ELSE 0 END) = 0
                     THEN 'ALL ASSERTIONS PASSED'
                     ELSE 'FAILURES PRESENT - see rows above' END
FROM   @results;

/*------------------------------------------------------------------- cleanup */
DELETE FROM core.AlertHistory  WHERE ServerName = @S;
DELETE FROM core.ResourceUsage WHERE ServerName = @S;
DELETE FROM core.DatabaseSpace WHERE ServerName = @S;
DELETE FROM core.BlockingChain WHERE ServerName = @S;
DELETE FROM core.FeedArrival   WHERE ServerName = @S;
DELETE FROM cfg.Target         WHERE ServerName = @S;
DELETE FROM core.ProcessRun    WHERE StepName LIKE 'EvaluateAlerts%';

PRINT 'Test data removed.';
GO
