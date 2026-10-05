/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 01-central/05-alerts.sql
  Run in : the CENTRAL repository database

  The alert engine runs centrally, on a schedule, over data that has already
  been normalized. It never touches a target database.

  Two properties matter more than the rule list:

  1. DE-DUPLICATION. A condition that is true for six hours produces ONE alert
     row, not seventy-two. The key is (ServerName, DatabaseName, AlertCode)
     among rows where ResolvedUtc IS NULL. If an open alert with that key
     already exists, the evaluation is a no-op.

  2. AUTO-RESOLVE. When the condition stops being true, the open row is stamped
     with ResolvedUtc. Nobody has to acknowledge anything for the dashboard to
     go green again. This is the difference between an alert table and a log.

  Thresholds all come from cfg.Setting, so tuning is an UPDATE, not a redeploy.
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
  core.usp_RaiseAlert - the only way an alert is created.
  Idempotent by design: calling it in a loop is safe.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE core.usp_RaiseAlert
    @ServerName     sysname,
    @DatabaseName   sysname,
    @AlertCode      varchar(50),
    @Severity       varchar(20),
    @Category       varchar(50),
    @Metric         nvarchar(128) = NULL,
    @ObservedValue  decimal(19,4) = NULL,
    @ThresholdValue decimal(19,4) = NULL,
    @Message        nvarchar(1000),
    @Detail         nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM core.AlertHistory
               WHERE ServerName   = @ServerName
                 AND DatabaseName = @DatabaseName
                 AND AlertCode    = @AlertCode
                 AND ResolvedUtc IS NULL)
    BEGIN
        /* already open - refresh the observed value so the dashboard shows the
           CURRENT number, not the number from when it first fired */
        UPDATE core.AlertHistory
           SET ObservedValue = @ObservedValue,
               Message       = @Message,
               Detail        = @Detail
         WHERE ServerName   = @ServerName
           AND DatabaseName = @DatabaseName
           AND AlertCode    = @AlertCode
           AND ResolvedUtc IS NULL;
        RETURN;
    END

    INSERT core.AlertHistory
        (ServerName, DatabaseName, RaisedUtc, AlertCode, Severity, Category,
         Metric, ObservedValue, ThresholdValue, Message, Detail)
    VALUES
        (@ServerName, @DatabaseName, SYSUTCDATETIME(), @AlertCode, @Severity, @Category,
         @Metric, @ObservedValue, @ThresholdValue, @Message, @Detail);
END
GO

/*------------------------------------------------------------------------------
  core.usp_ResolveAlerts - closes every open alert whose code is NOT in the
  list of codes that are still firing for that database.

  @StillFiring is a comma-separated list built by the evaluator. Codes absent
  from it are resolved. This is why the evaluator must run every rule every
  time: a rule that is skipped looks identical to a rule that passed.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE core.usp_ResolveAlerts
    @ServerName   sysname,
    @DatabaseName sysname,
    @StillFiring  nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE core.AlertHistory
       SET ResolvedUtc = SYSUTCDATETIME()
     WHERE ServerName   = @ServerName
       AND DatabaseName = @DatabaseName
       AND ResolvedUtc IS NULL
       AND AlertCode NOT IN (SELECT LTRIM(RTRIM(value))
                             FROM STRING_SPLIT(ISNULL(@StillFiring, ''), ',')
                             WHERE LTRIM(RTRIM(value)) <> '');
END
GO


/*==============================================================================
  core.usp_EvaluateAlerts - the rule set.

  Structure per database:
      collect the facts  ->  test each rule  ->  raise + record the code
      ->  resolve everything that did not fire

  Adding a rule means adding one IF block and appending its code to @fire.
==============================================================================*/
CREATE OR ALTER PROCEDURE core.usp_EvaluateAlerts
    @ServerName   sysname = NULL,   -- NULL = every enabled target
    @DatabaseName sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @runId bigint;
    INSERT core.ProcessRun (StepName, Status) VALUES ('EvaluateAlerts', 'Running');
    SET @runId = SCOPE_IDENTITY();

    DECLARE @raised int = 0, @resolved int = 0, @errors int = 0;
    DECLARE @beforeOpen int = (SELECT COUNT(*) FROM core.AlertHistory WHERE ResolvedUtc IS NULL);

    /*--- thresholds, read once -------------------------------------------*/
    DECLARE
        @cpuWarn      decimal(9,2) = cfg.fn_Dec('Alert.CpuWarnPct',        75),
        @cpuCrit      decimal(9,2) = cfg.fn_Dec('Alert.CpuCritPct',        90),
        @ioWarn       decimal(9,2) = cfg.fn_Dec('Alert.DataIoWarnPct',     80),
        @logWarn      decimal(9,2) = cfg.fn_Dec('Alert.LogWriteWarnPct',   80),
        @memWarn      decimal(9,2) = cfg.fn_Dec('Alert.MemoryWarnPct',     90),
        @wrkWarn      decimal(9,2) = cfg.fn_Dec('Alert.WorkerWarnPct',     70),
        @wrkCrit      decimal(9,2) = cfg.fn_Dec('Alert.WorkerCritPct',     90),
        @sesWarn      decimal(9,2) = cfg.fn_Dec('Alert.SessionWarnPct',    70),
        @spaceWarn    decimal(9,2) = cfg.fn_Dec('Alert.SpaceWarnPct',      80),
        @spaceCrit    decimal(9,2) = cfg.fn_Dec('Alert.SpaceCritPct',      90),
        @logSpaceWarn decimal(9,2) = cfg.fn_Dec('Alert.LogSpaceWarnPct',   75),
        @tempdbWarn   decimal(9,2) = cfg.fn_Dec('Alert.TempDbWarnPct',     70),
        @blockSec     int          = cfg.fn_Int('Alert.BlockingSeconds',   30),
        @blockCritSec int          = cfg.fn_Int('Alert.BlockingCritSeconds', 300),
        @deadlockMax  int          = cfg.fn_Int('Alert.DeadlocksPerDay',    3),
        @errSev       int          = cfg.fn_Int('Alert.ErrorSeverity',     17),
        @errCount     int          = cfg.fn_Int('Alert.ErrorCountPerHour',  5),
        @regressX     decimal(9,2) = cfg.fn_Dec('Alert.RegressionFactor',   2),
        @capDays      int          = cfg.fn_Int('Alert.CapacityWarnDays',  30),
        @capCritDays  int          = cfg.fn_Int('Alert.CapacityCritDays',   7),
        @fragPct      decimal(9,2) = cfg.fn_Dec('Alert.FragmentationPct',  30),
        @jobFailPct   decimal(9,2) = cfg.fn_Dec('Alert.JobFailurePct',     50),
        @longTranMin  int          = cfg.fn_Int('Alert.LongTransactionMinutes', 30);

    DECLARE @S sysname, @D sysname, @fire nvarchar(max), @msg nvarchar(1000),
            @det nvarchar(max), @v decimal(19,4), @v2 decimal(19,4), @txt nvarchar(max);

    DECLARE tgt CURSOR LOCAL FAST_FORWARD FOR
        SELECT ServerName, DatabaseName
        FROM   cfg.Target
        WHERE  IsEnabled = 1
          AND (@ServerName   IS NULL OR ServerName   = @ServerName)
          AND (@DatabaseName IS NULL OR DatabaseName = @DatabaseName);

    OPEN tgt;
    FETCH NEXT FROM tgt INTO @S, @D;

    WHILE @@FETCH_STATUS = 0
    BEGIN
      BEGIN TRY
        SET @fire = N'';

        /*==================================================================
          COLLECTION HEALTH - evaluated first, because if this fires the
          other rules are looking at stale data and would otherwise
          auto-resolve real problems.
        ==================================================================*/
        DECLARE @state varchar(20), @staleTiers nvarchar(200), @lastArrival datetime2(3);
        SELECT @state = CollectionState, @staleTiers = StaleTiers, @lastArrival = LastAnyArrivalUtc
        FROM   core.vw_TargetStatus WHERE ServerName = @S AND DatabaseName = @D;

        IF @state = 'NEVER'
        BEGIN
            SET @fire += N'COLLECTION_NEVER,';
            EXEC core.usp_RaiseAlert @S, @D, 'COLLECTION_NEVER', 'Critical', 'Collection',
                 N'FeedArrival rows', 0, 1,
                 N'No data has EVER arrived from this target.',
                 N'The target is registered in cfg.Target but no Elastic Job step has ever landed a row. Check core.vw_FeedDiagnosis for this database - it joins feed freshness to the job outcome and usually names the cause outright. Otherwise: (1) is the target in an EHD collection target group, (2) can the job agent identity connect to it, (3) is the job enabled and running.';
        END
        ELSE IF @state = 'CRITICAL'
        BEGIN
            SET @fire += N'COLLECTION_STALE,';
            SET @v = DATEDIFF(MINUTE, @lastArrival, SYSUTCDATETIME());
            /* @v is decimal(19,4) for the numeric-threshold columns, but a
               minute count must read as a whole number, not "300.0000". */
            SET @msg = N'Collection has stopped. Last arrival '
                     + CONVERT(nvarchar(30), CAST(@v AS bigint)) + N' minutes ago.';
            SET @det = N'Stale tiers: ' + ISNULL(@staleTiers, N'(unknown)')
                     + N'. Every other metric for this database is frozen at the last successful run and must not be trusted.';
            EXEC core.usp_RaiseAlert @S, @D, 'COLLECTION_STALE', 'Critical', 'Collection',
                 N'Minutes since last arrival', @v, NULL, @msg, @det;
        END
        ELSE IF @state = 'WARNING'
        BEGIN
            SET @fire += N'COLLECTION_PARTIAL,';
            SET @msg = N'Part of the collection pipeline has stopped: ' + ISNULL(@staleTiers, N'');
            EXEC core.usp_RaiseAlert @S, @D, 'COLLECTION_PARTIAL', 'Warning', 'Collection',
                 N'Stale tiers', NULL, NULL, @msg,
                 N'The frequent tier is still arriving, so live metrics are current, but the affected tier is not updating. Daily feeds (indexes, security, table space) go stale first and are the least urgent.';
        END

        /*==================================================================
          RESOURCE PRESSURE - averaged over the last 15 minutes so a single
          15-second spike does not page anyone.
        ==================================================================*/
        DECLARE @cpu decimal(9,2), @io decimal(9,2), @logw decimal(9,2),
                @mem decimal(9,2), @wrk decimal(9,2), @ses decimal(9,2), @n int;
        SELECT  @cpu = AVG(AvgCpuPct), @io = AVG(AvgDataIoPct), @logw = AVG(AvgLogWritePct),
                @mem = AVG(AvgMemoryPct), @wrk = MAX(MaxWorkerPct), @ses = MAX(MaxSessionPct),
                @n = COUNT(*)
        FROM    core.ResourceUsage
        WHERE   ServerName = @S AND DatabaseName = @D
          AND   EndTimeUtc >= DATEADD(MINUTE, -15, SYSUTCDATETIME());

        IF @n > 0
        BEGIN
            IF @cpu >= @cpuCrit
            BEGIN
                SET @fire += N'CPU_CRITICAL,';
                SET @msg = N'CPU averaged ' + CONVERT(nvarchar(10), @cpu) + N'% over 15 minutes.';
                EXEC core.usp_RaiseAlert @S, @D, 'CPU_CRITICAL', 'Critical', 'Resource',
                     N'AvgCpuPct', @cpu, @cpuCrit, @msg,
                     N'Sustained CPU at this level means queries are queuing. Check core.vw_TopQueries for this database ordered by TotalCpuSec, and core.vw_QueryRegression for a plan change.';
            END
            ELSE IF @cpu >= @cpuWarn
            BEGIN
                SET @fire += N'CPU_HIGH,';
                SET @msg = N'CPU averaged ' + CONVERT(nvarchar(10), @cpu) + N'% over 15 minutes.';
                EXEC core.usp_RaiseAlert @S, @D, 'CPU_HIGH', 'Warning', 'Resource',
                     N'AvgCpuPct', @cpu, @cpuWarn, @msg, NULL;
            END

            IF @io >= @ioWarn
            BEGIN
                SET @fire += N'DATA_IO_HIGH,';
                SET @msg = N'Data IO averaged ' + CONVERT(nvarchar(10), @io) + N'% of the tier limit.';
                EXEC core.usp_RaiseAlert @S, @D, 'DATA_IO_HIGH', 'Warning', 'Resource',
                     N'AvgDataIoPct', @io, @ioWarn, @msg,
                     N'At 100% the platform throttles IO and every query slows down. Look for missing indexes and scans in core.vw_MissingIndexTop.';
            END

            IF @logw >= @logWarn
            BEGIN
                SET @fire += N'LOG_WRITE_HIGH,';
                SET @msg = N'Log write averaged ' + CONVERT(nvarchar(10), @logw) + N'% of the tier limit.';
                EXEC core.usp_RaiseAlert @S, @D, 'LOG_WRITE_HIGH', 'Warning', 'Resource',
                     N'AvgLogWritePct', @logw, @logWarn, @msg,
                     N'The log rate governor throttles at 100%. Expect LOG_RATE_GOVERNOR waits. Batch smaller, or scale up.';
            END

            IF @wrk >= @wrkCrit
            BEGIN
                SET @fire += N'WORKERS_CRITICAL,';
                SET @msg = N'Worker threads peaked at ' + CONVERT(nvarchar(10), @wrk) + N'% of the tier limit.';
                EXEC core.usp_RaiseAlert @S, @D, 'WORKERS_CRITICAL', 'Critical', 'Resource',
                     N'MaxWorkerPct', @wrk, @wrkCrit, @msg,
                     N'At 100% new requests are refused with error 10928 and the database looks completely down to the application. Worker exhaustion is usually caused by blocking, not by load - check the Blocking detail first.';
            END
            ELSE IF @wrk >= @wrkWarn
            BEGIN
                SET @fire += N'WORKERS_HIGH,';
                SET @msg = N'Worker threads peaked at ' + CONVERT(nvarchar(10), @wrk) + N'% of the tier limit.';
                EXEC core.usp_RaiseAlert @S, @D, 'WORKERS_HIGH', 'Warning', 'Resource',
                     N'MaxWorkerPct', @wrk, @wrkWarn, @msg, NULL;
            END

            IF @ses >= @sesWarn
            BEGIN
                SET @fire += N'SESSIONS_HIGH,';
                SET @msg = N'Sessions peaked at ' + CONVERT(nvarchar(10), @ses) + N'% of the tier limit.';
                EXEC core.usp_RaiseAlert @S, @D, 'SESSIONS_HIGH', 'Warning', 'Resource',
                     N'MaxSessionPct', @ses, @sesWarn, @msg,
                     N'Usually a connection pool that is not returning connections. core.SessionActivity breaks the count down by program name.';
            END

            IF @mem >= @memWarn
            BEGIN
                SET @fire += N'MEMORY_HIGH,';
                SET @msg = N'Memory usage averaged ' + CONVERT(nvarchar(10), @mem) + N'%.';
                EXEC core.usp_RaiseAlert @S, @D, 'MEMORY_HIGH', 'Warning', 'Resource',
                     N'AvgMemoryPct', @mem, @memWarn, @msg,
                     N'High memory alone is normal - SQL Server uses what it is given. Only act if RESOURCE_SEMAPHORE waits also appear in core.vw_TopWaits.';
            END
        END

        /*==================================================================
          STORAGE AND CAPACITY
        ==================================================================*/
        SELECT TOP (1) @v = PctOfMaxSize, @v2 = MaxSizeMB - UsedMB
        FROM   core.DatabaseSpace
        WHERE  ServerName = @S AND DatabaseName = @D
        ORDER BY SnapshotUtc DESC;

        IF @v >= @spaceCrit
        BEGIN
            SET @fire += N'SPACE_CRITICAL,';
            SET @msg = N'Database is ' + CONVERT(nvarchar(20), CAST(@v AS decimal(9,2))) + N'% of MAXSIZE ('
                     + CONVERT(nvarchar(20), CAST(@v2 AS int)) + N' MB free).';
            EXEC core.usp_RaiseAlert @S, @D, 'SPACE_CRITICAL', 'Critical', 'Capacity',
                 N'PctOfMaxSize', @v, @spaceCrit, @msg,
                 N'At 100% every INSERT fails with error 40544 and the application is down. Raise MAXSIZE or scale the tier NOW - this is not a maintenance-window problem.';
        END
        ELSE IF @v >= @spaceWarn
        BEGIN
            SET @fire += N'SPACE_HIGH,';
            SET @msg = N'Database is ' + CONVERT(nvarchar(20), CAST(@v AS decimal(9,2))) + N'% of MAXSIZE.';
            EXEC core.usp_RaiseAlert @S, @D, 'SPACE_HIGH', 'Warning', 'Capacity',
                 N'PctOfMaxSize', @v, @spaceWarn, @msg, NULL;
        END

        SET @v = NULL;
        SELECT @v = DaysUntilFull, @txt = Verdict
        FROM   core.vw_CapacityForecast WHERE ServerName = @S AND DatabaseName = @D;

        IF @v IS NOT NULL AND @v <= @capCritDays
        BEGIN
            SET @fire += N'CAPACITY_CRITICAL,';
            SET @msg = N'Projected to reach MAXSIZE in ' + CONVERT(nvarchar(10), CAST(@v AS int)) + N' days.';
            EXEC core.usp_RaiseAlert @S, @D, 'CAPACITY_CRITICAL', 'Critical', 'Capacity',
                 N'DaysUntilFull', @v, @capCritDays, @msg,
                 N'Straight-line projection from the last 30 days of growth. Check Confidence in core.vw_CapacityForecast before acting - a Low confidence figure is based on very few samples.';
        END
        ELSE IF @v IS NOT NULL AND @v <= @capDays
        BEGIN
            SET @fire += N'CAPACITY_WARNING,';
            SET @msg = N'Projected to reach MAXSIZE in ' + CONVERT(nvarchar(10), CAST(@v AS int)) + N' days.';
            EXEC core.usp_RaiseAlert @S, @D, 'CAPACITY_WARNING', 'Warning', 'Capacity',
                 N'DaysUntilFull', @v, @capDays, @msg, NULL;
        END

        SET @v = NULL; SET @txt = NULL;
        SELECT TOP (1) @v = UsedLogSpacePct, @txt = LogReuseWaitDesc
        FROM   core.LogSpace WHERE ServerName = @S AND DatabaseName = @D
        ORDER BY SnapshotUtc DESC;

        IF @v >= @logSpaceWarn
        BEGIN
            SET @fire += N'LOG_SPACE_HIGH,';
            SET @msg = N'Transaction log is ' + CONVERT(nvarchar(20), CAST(@v AS decimal(9,2))) + N'% used (reuse wait: '
                     + ISNULL(@txt, N'NOTHING') + N').';
            EXEC core.usp_RaiseAlert @S, @D, 'LOG_SPACE_HIGH', 'Warning', 'Capacity',
                 N'UsedLogSpacePct', @v, @logSpaceWarn, @msg,
                 N'If the reuse wait is ACTIVE_TRANSACTION, a long-running transaction is pinning the log - see OldestTranSessionId in core.LogSpace. If it is AVAILABILITY_REPLICA, a geo-replica is behind.';
        END

        /* an open transaction pinning the log is worth its own alert */
        SET @v = NULL;
        SELECT TOP (1) @v = DATEDIFF(MINUTE, OldestTranBeginUtc, SnapshotUtc)
        FROM   core.LogSpace
        WHERE  ServerName = @S AND DatabaseName = @D AND OldestTranBeginUtc IS NOT NULL
        ORDER BY SnapshotUtc DESC;

        IF @v >= @longTranMin
        BEGIN
            SET @fire += N'LONG_TRANSACTION,';
            SET @msg = N'A transaction has been open for ' + CONVERT(nvarchar(10), CAST(@v AS int)) + N' minutes.';
            EXEC core.usp_RaiseAlert @S, @D, 'LONG_TRANSACTION', 'Warning', 'Concurrency',
                 N'Open transaction minutes', @v, @longTranMin, @msg,
                 N'A long open transaction blocks log truncation and holds locks. Most often an application that opened a transaction and never committed.';
        END

        SET @v = NULL;
        SELECT TOP (1) @v = PctUsed FROM core.TempDbUsage
        WHERE  ServerName = @S AND DatabaseName = @D ORDER BY SnapshotUtc DESC;

        IF @v >= @tempdbWarn
        BEGIN
            SET @fire += N'TEMPDB_HIGH,';
            SET @msg = N'TempDB is ' + CONVERT(nvarchar(20), CAST(@v AS decimal(9,2))) + N'% used.';
            EXEC core.usp_RaiseAlert @S, @D, 'TEMPDB_HIGH', 'Warning', 'Capacity',
                 N'TempDb PctUsed', @v, @tempdbWarn, @msg,
                 N'TempDB is shared per database in Azure SQL DB. Look at VersionStoreMB - if it dominates, a long-running snapshot-isolation reader is the cause.';
        END

        /*==================================================================
          CONCURRENCY
        ==================================================================*/
        SET @v = NULL; SET @v2 = NULL;
        SELECT @v = MAX(WaitDurationMs) / 1000.0, @v2 = COUNT(DISTINCT HeadBlockerSessionId)
        FROM   core.BlockingChain
        WHERE  ServerName = @S AND DatabaseName = @D
          AND  SnapshotUtc >= DATEADD(MINUTE, -15, SYSUTCDATETIME());

        IF @v >= @blockCritSec
        BEGIN
            SET @fire += N'BLOCKING_CRITICAL,';
            SET @msg = N'Blocking lasting ' + CONVERT(nvarchar(20), CAST(@v AS int))
                     + N' seconds across ' + CONVERT(nvarchar(10), CAST(@v2 AS int)) + N' chain(s).';
            SET @det = (SELECT TOP (1) CONCAT(N'Head blocker session ', HeadBlockerSessionId,
                               N' (', ISNULL(BlockerProgram, N'?'), N' / ', ISNULL(BlockerLogin, N'?'),
                               N', status=', ISNULL(BlockerStatus, N'?'), N'): ',
                               LEFT(ISNULL(BlockerSql, N'(no text captured)'), 500))
                        FROM core.BlockingChain
                        WHERE ServerName = @S AND DatabaseName = @D
                          AND SnapshotUtc >= DATEADD(MINUTE, -15, SYSUTCDATETIME())
                        ORDER BY WaitDurationMs DESC);
            EXEC core.usp_RaiseAlert @S, @D, 'BLOCKING_CRITICAL', 'Critical', 'Concurrency',
                 N'Max block seconds', @v, @blockCritSec, @msg, @det;
        END
        ELSE IF @v >= @blockSec
        BEGIN
            SET @fire += N'BLOCKING,';
            SET @msg = N'Blocking lasting ' + CONVERT(nvarchar(20), CAST(@v AS int)) + N' seconds.';
            EXEC core.usp_RaiseAlert @S, @D, 'BLOCKING', 'Warning', 'Concurrency',
                 N'Max block seconds', @v, @blockSec, @msg, NULL;
        END

        SET @v = NULL;
        SELECT @v = COUNT(*) FROM core.Deadlock
        WHERE  ServerName = @S AND DatabaseName = @D
          AND  EventTimeUtc >= DATEADD(DAY, -1, SYSUTCDATETIME());

        IF @v > @deadlockMax
        BEGIN
            SET @fire += N'DEADLOCKS,';
            SET @msg = CONVERT(nvarchar(10), CAST(@v AS int)) + N' deadlocks in the last 24 hours.';
            SET @det = (SELECT TOP (1) CONCAT(N'Most recent victim: ', LEFT(ISNULL(VictimSql, N'(none)'), 500),
                                              N' | objects: ', ISNULL(ObjectsInvolved, N'?'))
                        FROM core.Deadlock
                        WHERE ServerName = @S AND DatabaseName = @D
                        ORDER BY EventTimeUtc DESC);
            EXEC core.usp_RaiseAlert @S, @D, 'DEADLOCKS', 'Warning', 'Concurrency',
                 N'Deadlocks per day', @v, @deadlockMax, @msg, @det;
        END

        /*==================================================================
          ERRORS
        ==================================================================*/
        SET @v = NULL;
        SELECT @v = COUNT(*) FROM core.ErrorEvent
        WHERE  ServerName = @S AND DatabaseName = @D
          AND  Severity >= @errSev
          AND  EventTimeUtc >= DATEADD(HOUR, -1, SYSUTCDATETIME());

        IF @v >= @errCount
        BEGIN
            SET @fire += N'ERROR_BURST,';
            SET @msg = CONVERT(nvarchar(10), CAST(@v AS int)) + N' errors of severity '
                     + CONVERT(nvarchar(5), @errSev) + N'+ in the last hour.';
            SET @det = (SELECT STRING_AGG(CONVERT(nvarchar(max),
                               CONCAT(N'Err ', ErrorNumber, N' x', Occurrences, N': ',
                                      LEFT(SampleMessage, 200))), NCHAR(13) + NCHAR(10))
                        FROM (SELECT TOP (5) ErrorNumber, Occurrences, SampleMessage
                              FROM core.vw_ErrorSummary
                              WHERE ServerName = @S AND DatabaseName = @D AND Severity >= @errSev
                              ORDER BY Occurrences DESC) AS x);
            EXEC core.usp_RaiseAlert @S, @D, 'ERROR_BURST', 'Critical', 'Errors',
                 N'Errors per hour', @v, @errCount, @msg, @det;
        END

        /*==================================================================
          PERFORMANCE REGRESSION
        ==================================================================*/
        SET @v = NULL;
        SELECT TOP (1) @v = CpuRegressionX, @txt = LEFT(SampleSql, 500)
        FROM   core.vw_QueryRegression
        WHERE  ServerName = @S AND DatabaseName = @D
        ORDER BY CpuRegressionX DESC;

        IF @v >= @regressX
        BEGIN
            SET @fire += N'QUERY_REGRESSION,';
            SET @msg = N'A query is running ' + CONVERT(nvarchar(20), CAST(@v AS decimal(9,2)))
                     + N'x slower than its 7-day baseline.';
            SET @det = N'Worst offender: ' + ISNULL(@txt, N'(no text)')
                     + NCHAR(13) + NCHAR(10)
                     + N'Full list: SELECT * FROM core.vw_QueryRegression WHERE ServerName = '''
                     + @S + N''' AND DatabaseName = ''' + @D + N''' ORDER BY CpuRegressionX DESC;';
            EXEC core.usp_RaiseAlert @S, @D, 'QUERY_REGRESSION', 'Warning', 'Performance',
                 N'CPU regression factor', @v, @regressX, @msg, @det;
        END

        /*==================================================================
          MAINTENANCE - daily-tier data, so these resolve slowly by design.
        ==================================================================*/
        SET @v = NULL;
        SELECT @v = COUNT(*) FROM core.vw_FragmentationWork
        WHERE  ServerName = @S AND DatabaseName = @D AND AvgFragmentationPct >= @fragPct;

        IF @v > 0
        BEGIN
            SET @fire += N'FRAGMENTATION,';
            SET @msg = CONVERT(nvarchar(10), CAST(@v AS int)) + N' indexes are over '
                     + CONVERT(nvarchar(10), @fragPct) + N'% fragmented.';
            EXEC core.usp_RaiseAlert @S, @D, 'FRAGMENTATION', 'Info', 'Maintenance',
                 N'Fragmented indexes', @v, 0, @msg,
                 N'core.vw_FragmentationWork generates the exact ALTER INDEX statements, ONLINE and RESUMABLE. Nothing is executed automatically - this system never writes to a target.';
        END

        /*==================================================================
          SECURITY
        ==================================================================*/
        SET @v = NULL;
        SELECT @v = COUNT(*) FROM core.vw_SecurityDrift
        WHERE  ServerName = @S AND DatabaseName = @D AND Severity = 'Critical';

        IF @v > 0
        BEGIN
            SET @fire += N'SECURITY_PRIVILEGE,';
            SET @msg = CONVERT(nvarchar(10), CAST(@v AS int)) + N' principal(s) gained high privilege since the last snapshot.';
            SET @det = (SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(Subject, N': ', Detail)),
                                          NCHAR(13) + NCHAR(10))
                        FROM core.vw_SecurityDrift
                        WHERE ServerName = @S AND DatabaseName = @D AND Severity = 'Critical');
            EXEC core.usp_RaiseAlert @S, @D, 'SECURITY_PRIVILEGE', 'Critical', 'Security',
                 N'Privilege escalations', @v, 0, @msg, @det;
        END

        SET @v = NULL;
        SELECT @v = COUNT(*) FROM core.vw_SecurityDrift
        WHERE  ServerName = @S AND DatabaseName = @D AND Severity = 'Warning';

        IF @v > 0
        BEGIN
            SET @fire += N'SECURITY_DRIFT,';
            SET @msg = CONVERT(nvarchar(10), CAST(@v AS int)) + N' principal or role change(s) since the last snapshot.';
            /* T-SQL does not allow an expression as an EXEC argument - build it first */
            SET @det = N'Compare snapshots: SELECT * FROM core.vw_SecurityDrift WHERE ServerName = '''
                     + @S + N''' AND DatabaseName = ''' + @D + N''';';
            EXEC core.usp_RaiseAlert @S, @D, 'SECURITY_DRIFT', 'Warning', 'Security',
                 N'Principal changes', @v, 0, @msg, @det;
        END

        /*==================================================================
          PLATFORM CHANGE - somebody scaled the database.
        ==================================================================*/
        IF EXISTS (SELECT 1 FROM core.ServiceObjectiveChange
                   WHERE ServerName = @S AND DatabaseName = @D
                     AND DetectedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME()))
        BEGIN
            SET @fire += N'TIER_CHANGED,';
            SELECT TOP (1) @det = CONCAT(N'Changed from ', ISNULL(PreviousObjective, N'(unknown)'),
                                         N' to ', ServiceObjective, N' at ',
                                         CONVERT(nvarchar(30), DetectedUtc, 126), N' UTC.')
            FROM   core.ServiceObjectiveChange
            WHERE  ServerName = @S AND DatabaseName = @D
            ORDER BY DetectedUtc DESC;
            EXEC core.usp_RaiseAlert @S, @D, 'TIER_CHANGED', 'Info', 'Platform',
                 N'Service objective', NULL, NULL,
                 N'The service tier of this database changed in the last 24 hours.', @det;
        END

        /*==================================================================
          XE SESSION HEALTH - an XE session that is dropping events is worse
          than no session at all, because it looks like it is working.

          THE HEALTHY VALUE IS 'Healthy', NOT 'OK'.
          The collector (22-jobs-standard.sql, step XeHealth) emits one of:
              'Healthy'
              'NOT RUNNING - no data being captured'
              'Blocking the workload'
              'Dropping buffers - raise MAX_MEMORY'
              'Dropping events - tighten predicates'
          It never emits 'OK'. This rule originally tested Verdict <> 'OK',
          which therefore matched EVERY healthy session and raised a permanent
          false XE_UNHEALTHY alert on every monitored database - a warning that
          is always on is a warning nobody reads.

          If you change the collector's vocabulary, change it here too. The two
          are coupled and nothing enforces it.
        ==================================================================*/
        IF EXISTS (SELECT 1 FROM core.XeSessionHealth h
                   JOIN (SELECT ServerName, DatabaseName, M = MAX(SnapshotUtc)
                         FROM core.XeSessionHealth GROUP BY ServerName, DatabaseName) m
                     ON m.ServerName = h.ServerName AND m.DatabaseName = h.DatabaseName
                        AND m.M = h.SnapshotUtc
                   WHERE h.ServerName = @S AND h.DatabaseName = @D
                     AND h.Verdict NOT IN ('OK', 'Healthy'))
        BEGIN
            SET @fire += N'XE_UNHEALTHY,';
            SELECT TOP (1) @det = CONCAT(N'Session ', SessionName, N': state=', State,
                                         N', dropped events=', DroppedEventCount,
                                         N', dropped buffers=', DroppedBufferCount,
                                         N' -> ', Verdict)
            FROM   core.XeSessionHealth
            WHERE  ServerName = @S AND DatabaseName = @D
              AND  Verdict NOT IN ('OK', 'Healthy')
            ORDER BY SnapshotUtc DESC;
            EXEC core.usp_RaiseAlert @S, @D, 'XE_UNHEALTHY', 'Warning', 'Collection',
                 N'XE session', NULL, NULL,
                 N'An Extended Events session is stopped or dropping events - error and deadlock capture is incomplete.', @det;
        END

        /*==================================================================
          COLLECTION JOB FAILURES

          Only possible because the agent and the repository are one database.
          core.FeedArrival says a feed is stale; jobs.job_executions says why.
          This rule reports the reason rather than the symptom.

          Guarded on OBJECT_ID so the engine still runs if 04-job-health.sql
          has not been deployed yet.
        ==================================================================*/
        IF OBJECT_ID('core.vw_JobHealth') IS NOT NULL
        BEGIN
            SET @v = NULL; SET @v2 = NULL; SET @txt = NULL;

            SELECT  @v  = MAX(FailurePct),
                    @v2 = SUM(Failures24h),
                    @txt = MAX(LastError)
            FROM    core.vw_JobHealth
            WHERE   ServerName = @S AND DatabaseName = @D
              AND   JobTier IN ('Frequent','Standard','Daily')
              AND   Failures24h > 0;

            IF @v >= @jobFailPct
            BEGIN
                SET @fire += N'JOB_FAILING,';
                SET @msg = CONVERT(nvarchar(10), CAST(@v2 AS int))
                         + N' collection job failure(s) in 24 h ('
                         + CONVERT(nvarchar(20), CAST(@v AS decimal(9,2))) + N'% of attempts).';
                SET @det = N'Last error: ' + ISNULL(@txt, N'(no message recorded)')
                         + NCHAR(13) + NCHAR(10)
                         + N'Full picture: SELECT * FROM core.vw_FeedDiagnosis WHERE DatabaseName = '''
                         + @D + N''';';
                EXEC core.usp_RaiseAlert @S, @D, 'JOB_FAILING', 'Critical', 'Collection',
                     N'Job failure %', @v, @jobFailPct, @msg, @det;
            END
        END

        /*--- everything that did NOT fire gets closed -----------------------*/
        EXEC core.usp_ResolveAlerts @S, @D, @fire;

      END TRY
      BEGIN CATCH
        SET @errors += 1;
        /* one bad target must not abort the whole evaluation pass */
        INSERT core.ProcessRun (StepName, CompletedUtc, Status, ErrorNumber, ErrorMessage)
        VALUES (CONCAT('EvaluateAlerts:', @D), SYSUTCDATETIME(), 'Failed',
                ERROR_NUMBER(), CONCAT('Line ', ERROR_LINE(), ': ', ERROR_MESSAGE()));
      END CATCH

      FETCH NEXT FROM tgt INTO @S, @D;
    END

    CLOSE tgt; DEALLOCATE tgt;

    DECLARE @afterOpen int = (SELECT COUNT(*) FROM core.AlertHistory WHERE ResolvedUtc IS NULL);

    UPDATE core.ProcessRun
       SET CompletedUtc = SYSUTCDATETIME(),
           Status       = CASE WHEN @errors > 0 THEN 'PartialSuccess' ELSE 'Success' END,
           RowsAffected = @afterOpen,
           ErrorMessage = CASE WHEN @errors > 0
                               THEN CONCAT(@errors, ' target(s) failed evaluation - see earlier ProcessRun rows')
                          END
     WHERE ProcessRunId = @runId;

    SELECT OpenAlertsBefore = @beforeOpen, OpenAlertsAfter = @afterOpen, TargetErrors = @errors;
END
GO

PRINT '=== alert engine deployed ===';
GO
