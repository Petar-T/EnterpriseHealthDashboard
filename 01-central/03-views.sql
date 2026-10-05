/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 01-central/03-views.sql
  Run in : the CENTRAL repository database

  This is what the central design buys you. In the embedded edition, "which
  database in the estate has the worst blocking?" meant querying every database
  and stitching the answers together client-side. Here it is ORDER BY.

  Naming:
      core.vw_Fleet*   one row per database - estate-wide ranking
      core.vw_*        per-database detail, filtered by (ServerName, DatabaseName)
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
  TARGET INVENTORY - the registry joined to what has actually arrived.
  A registered target with no recent arrival is the most important row in the
  whole system: it means monitoring has silently stopped.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_TargetStatus
AS
WITH arrival AS
(
    SELECT ServerName, DatabaseName,
           LastAnyArrivalUtc = MAX(LastArrivalUtc),
           LastFrequentUtc   = MAX(CASE WHEN Tier = 'Frequent' THEN LastArrivalUtc END),
           LastStandardUtc   = MAX(CASE WHEN Tier = 'Standard' THEN LastArrivalUtc END),
           LastDailyUtc      = MAX(CASE WHEN Tier = 'Daily'    THEN LastArrivalUtc END),
           FeedCount         = COUNT(*)
    FROM   core.FeedArrival
    GROUP BY ServerName, DatabaseName
)
SELECT  t.ServerName,
        t.DatabaseName,
        t.Environment,
        t.Owner,
        t.Criticality,
        t.IsVendorOwned,
        t.IsEnabled,
        a.LastAnyArrivalUtc,
        a.LastFrequentUtc,
        a.LastStandardUtc,
        a.LastDailyUtc,
        FeedCount = ISNULL(a.FeedCount, 0),
        FrequentAgeMin = DATEDIFF(MINUTE, a.LastFrequentUtc, SYSUTCDATETIME()),
        StandardAgeMin = DATEDIFF(MINUTE, a.LastStandardUtc, SYSUTCDATETIME()),
        DailyAgeMin    = DATEDIFF(MINUTE, a.LastDailyUtc,    SYSUTCDATETIME()),
        CollectionState = CASE
            WHEN t.IsEnabled = 0                    THEN 'DISABLED'
            WHEN a.LastAnyArrivalUtc IS NULL        THEN 'NEVER'
            WHEN DATEDIFF(MINUTE, a.LastFrequentUtc, SYSUTCDATETIME())
                 > cfg.fn_Int('Stale.FrequentMinutes', 20)
              OR a.LastFrequentUtc IS NULL          THEN 'CRITICAL'
            WHEN DATEDIFF(MINUTE, a.LastStandardUtc, SYSUTCDATETIME())
                 > cfg.fn_Int('Stale.StandardMinutes', 90)
              OR a.LastStandardUtc IS NULL          THEN 'WARNING'
            WHEN DATEDIFF(MINUTE, a.LastDailyUtc, SYSUTCDATETIME())
                 > cfg.fn_Int('Stale.DailyMinutes', 1560)
              OR a.LastDailyUtc IS NULL             THEN 'WARNING'
            ELSE 'OK' END,
        StaleTiers = STUFF(
              CASE WHEN a.LastFrequentUtc IS NULL
                     OR DATEDIFF(MINUTE, a.LastFrequentUtc, SYSUTCDATETIME()) > cfg.fn_Int('Stale.FrequentMinutes', 20)
                   THEN ', Frequent' ELSE '' END
            + CASE WHEN a.LastStandardUtc IS NULL
                     OR DATEDIFF(MINUTE, a.LastStandardUtc, SYSUTCDATETIME()) > cfg.fn_Int('Stale.StandardMinutes', 90)
                   THEN ', Standard' ELSE '' END
            + CASE WHEN a.LastDailyUtc IS NULL
                     OR DATEDIFF(MINUTE, a.LastDailyUtc, SYSUTCDATETIME()) > cfg.fn_Int('Stale.DailyMinutes', 1560)
                   THEN ', Daily' ELSE '' END, 1, 2, '')
FROM    cfg.Target AS t
LEFT JOIN arrival AS a ON a.ServerName = t.ServerName AND a.DatabaseName = t.DatabaseName;
GO


/*------------------------------------------------------------------------------
  WAIT DELTAS - computed centrally, because targets cannot hold state.
  Negative deltas mean the counter reset (failover, scale, restart) and are
  discarded rather than reported as enormous spikes.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_WaitStatsDelta
AS
WITH seq AS
(
    SELECT  ServerName, DatabaseName, SnapshotUtc, WaitType,
            WaitingTasksCount, WaitTimeMs, SignalWaitTimeMs, MaxWaitTimeMs,
            PrevUtc    = LAG(SnapshotUtc)       OVER (PARTITION BY ServerName, DatabaseName, WaitType ORDER BY SnapshotUtc),
            PrevTasks  = LAG(WaitingTasksCount) OVER (PARTITION BY ServerName, DatabaseName, WaitType ORDER BY SnapshotUtc),
            PrevWait   = LAG(WaitTimeMs)        OVER (PARTITION BY ServerName, DatabaseName, WaitType ORDER BY SnapshotUtc),
            PrevSignal = LAG(SignalWaitTimeMs)  OVER (PARTITION BY ServerName, DatabaseName, WaitType ORDER BY SnapshotUtc)
    FROM    core.WaitStats
)
SELECT  ServerName, DatabaseName, SnapshotUtc, WaitType,
        IntervalSeconds = DATEDIFF(SECOND, PrevUtc, SnapshotUtc),
        WaitCount       = WaitingTasksCount - PrevTasks,
        WaitTimeMs      = WaitTimeMs        - PrevWait,
        SignalWaitMs    = SignalWaitTimeMs  - PrevSignal,
        ResourceWaitMs  = (WaitTimeMs - PrevWait) - (SignalWaitTimeMs - PrevSignal),
        MaxWaitTimeMs,
        AvgWaitMs = CASE WHEN (WaitingTasksCount - PrevTasks) > 0
                         THEN (WaitTimeMs - PrevWait) * 1.0 / (WaitingTasksCount - PrevTasks) END
FROM    seq
WHERE   PrevUtc IS NOT NULL
  AND   WaitTimeMs        >= PrevWait
  AND   WaitingTasksCount >= PrevTasks;
GO

/*------------------------------------------------------------------------------
  TOP WAITS - per database, last 24 h, with plain-English interpretation.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_TopWaits
AS
SELECT  ServerName, DatabaseName, WaitType,
        ResourceWaitSec = CAST(SUM(ResourceWaitMs) / 1000.0 AS decimal(19,2)),
        TotalWaitSec    = CAST(SUM(WaitTimeMs)     / 1000.0 AS decimal(19,2)),
        WaitCount       = SUM(WaitCount),
        AvgWaitMs       = CAST(CASE WHEN SUM(WaitCount) > 0
                                    THEN SUM(WaitTimeMs) * 1.0 / SUM(WaitCount) END AS decimal(19,2)),
        MaxWaitMs       = MAX(MaxWaitTimeMs),
        PctOfTotal      = CAST(SUM(WaitTimeMs) * 100.0
                               / NULLIF(SUM(SUM(WaitTimeMs)) OVER (PARTITION BY ServerName, DatabaseName), 0) AS decimal(9,2)),
        Interpretation  = CASE
            WHEN WaitType LIKE 'LCK[_]M[_]%'             THEN 'Blocking - see the Blocking detail'
            WHEN WaitType LIKE 'PAGEIOLATCH[_]%'         THEN 'Reading data from storage - memory pressure or missing index'
            WHEN WaitType = 'WRITELOG'                   THEN 'Log write latency - batch commits, check log rate governor'
            WHEN WaitType LIKE 'LOG_RATE_GOVERNOR%'      THEN 'THROTTLED: hitting the tier log write limit - scale up'
            WHEN WaitType LIKE 'HADR_THROTTLE_LOG_RATE%' THEN 'THROTTLED: log rate capped by replication - scale up'
            WHEN WaitType LIKE 'SE_REPL[_]%'             THEN 'Waiting on a geo/HA replica to acknowledge'
            WHEN WaitType LIKE 'RESOURCE_SEMAPHORE%'     THEN 'Memory grant starvation - oversized grants or too few resources'
            WHEN WaitType = 'SOS_SCHEDULER_YIELD'        THEN 'CPU pressure - queries queuing for a scheduler'
            WHEN WaitType = 'THREADPOOL'                 THEN 'Worker starvation - too many concurrent requests for the tier'
            WHEN WaitType LIKE 'CXPACKET%'
              OR WaitType LIKE 'CXCONSUMER%'             THEN 'Parallelism skew - review MAXDOP / cost threshold'
            WHEN WaitType LIKE 'PAGELATCH[_]%'           THEN 'In-memory page contention - hot page / tempdb allocation'
            WHEN WaitType = 'ASYNC_NETWORK_IO'           THEN 'Client is not consuming results fast enough (not a SQL problem)'
            WHEN WaitType LIKE 'IO_QUEUE_LIMIT%'
              OR WaitType LIKE 'IO_RETRY%'               THEN 'THROTTLED: hitting the tier IOPS limit - scale up'
            WHEN WaitType LIKE 'RBIO[_]%'                THEN 'Hyperscale page server IO'
            ELSE 'See sys.dm_os_wait_stats documentation' END
FROM    core.vw_WaitStatsDelta
WHERE   SnapshotUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, WaitType;
GO


/*------------------------------------------------------------------------------
  QUERY DELTAS and REGRESSION - both cross-database.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_QueryStatsDelta
AS
WITH seq AS
(
    SELECT  ServerName, DatabaseName, SnapshotUtc, QueryHash, QueryPlanHash,
            ObjectName, SampleSqlText,
            ExecutionCount, TotalWorkerTimeUs, TotalElapsedTimeUs, TotalLogicalReads,
            PrevUtc    = LAG(SnapshotUtc)        OVER (PARTITION BY ServerName, DatabaseName, QueryHash, QueryPlanHash ORDER BY SnapshotUtc),
            PrevExec   = LAG(ExecutionCount)     OVER (PARTITION BY ServerName, DatabaseName, QueryHash, QueryPlanHash ORDER BY SnapshotUtc),
            PrevWorker = LAG(TotalWorkerTimeUs)  OVER (PARTITION BY ServerName, DatabaseName, QueryHash, QueryPlanHash ORDER BY SnapshotUtc),
            PrevElapsed= LAG(TotalElapsedTimeUs) OVER (PARTITION BY ServerName, DatabaseName, QueryHash, QueryPlanHash ORDER BY SnapshotUtc),
            PrevReads  = LAG(TotalLogicalReads)  OVER (PARTITION BY ServerName, DatabaseName, QueryHash, QueryPlanHash ORDER BY SnapshotUtc)
    FROM    core.QueryStats
)
SELECT  ServerName, DatabaseName, SnapshotUtc, QueryHash, QueryPlanHash, ObjectName, SampleSqlText,
        Executions    = ExecutionCount     - PrevExec,
        WorkerTimeMs  = (TotalWorkerTimeUs - PrevWorker)  / 1000,
        ElapsedTimeMs = (TotalElapsedTimeUs- PrevElapsed) / 1000,
        LogicalReads  = TotalLogicalReads  - PrevReads,
        AvgWorkerMs   = CASE WHEN (ExecutionCount - PrevExec) > 0
                             THEN (TotalWorkerTimeUs - PrevWorker) / 1000.0 / (ExecutionCount - PrevExec) END
FROM    seq
WHERE   PrevUtc IS NOT NULL
  AND   ExecutionCount    >= PrevExec
  AND   TotalWorkerTimeUs >= PrevWorker
  AND   ExecutionCount    >  PrevExec;
GO

CREATE OR ALTER VIEW core.vw_TopQueries
AS
SELECT  ServerName, DatabaseName, QueryHash,
        Executions       = SUM(Executions),
        TotalCpuSec      = CAST(SUM(WorkerTimeMs)  / 1000.0 AS decimal(19,2)),
        TotalElapsedSec  = CAST(SUM(ElapsedTimeMs) / 1000.0 AS decimal(19,2)),
        AvgCpuMs         = CAST(SUM(WorkerTimeMs)  * 1.0 / NULLIF(SUM(Executions),0) AS decimal(19,2)),
        AvgLogicalReads  = CAST(SUM(LogicalReads)  * 1.0 / NULLIF(SUM(Executions),0) AS decimal(19,2)),
        PlanCount        = COUNT(DISTINCT QueryPlanHash),
        ObjectName       = MIN(ObjectName),
        SampleSqlText    = MIN(SampleSqlText),
        FirstSeenUtc     = MIN(SnapshotUtc),
        LastSeenUtc      = MAX(SnapshotUtc)
FROM    core.vw_QueryStatsDelta
WHERE   SnapshotUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, QueryHash;
GO

CREATE OR ALTER VIEW core.vw_QueryRegression
AS
WITH baseline AS
(
    SELECT  ServerName, DatabaseName, QueryHash,
            BaseExecs  = SUM(Executions),
            BaseAvgCpu = SUM(WorkerTimeMs) * 1.0 / NULLIF(SUM(Executions), 0),
            BasePlans  = COUNT(DISTINCT QueryPlanHash)
    FROM    core.vw_QueryStatsDelta
    WHERE   SnapshotUtc >= DATEADD(DAY,  -7, SYSUTCDATETIME())
      AND   SnapshotUtc <  DATEADD(HOUR, -6, SYSUTCDATETIME())
    GROUP BY ServerName, DatabaseName, QueryHash
    HAVING  SUM(Executions) >= 10
),
current_ AS
(
    SELECT  ServerName, DatabaseName, QueryHash,
            CurExecs   = SUM(Executions),
            CurAvgCpu  = SUM(WorkerTimeMs) * 1.0 / NULLIF(SUM(Executions), 0),
            CurPlans   = COUNT(DISTINCT QueryPlanHash),
            SampleSql  = MIN(SampleSqlText),
            ObjectName = MIN(ObjectName)
    FROM    core.vw_QueryStatsDelta
    WHERE   SnapshotUtc >= DATEADD(HOUR, -6, SYSUTCDATETIME())
    GROUP BY ServerName, DatabaseName, QueryHash
    HAVING  SUM(Executions) >= 5
)
SELECT  c.ServerName, c.DatabaseName, c.QueryHash, c.ObjectName,
        BaseAvgCpuMs   = CAST(b.BaseAvgCpu AS decimal(19,2)),
        CurAvgCpuMs    = CAST(c.CurAvgCpu  AS decimal(19,2)),
        CpuRegressionX = CAST(c.CurAvgCpu / NULLIF(b.BaseAvgCpu, 0) AS decimal(9,2)),
        b.BaseExecs, c.CurExecs,
        PlanCountChange = c.CurPlans - b.BasePlans,
        Verdict = CASE WHEN c.CurAvgCpu > b.BaseAvgCpu * 3 THEN 'SEVERE regression (3x+ CPU)'
                       WHEN c.CurAvgCpu > b.BaseAvgCpu * 2 THEN 'Regression (2x+ CPU)'
                       WHEN c.CurExecs  > b.BaseExecs  * 5 THEN 'Execution count spike'
                       ELSE 'Watch' END,
        c.SampleSql
FROM    current_ AS c
JOIN    baseline AS b
     ON b.ServerName = c.ServerName AND b.DatabaseName = c.DatabaseName AND b.QueryHash = c.QueryHash
WHERE   c.CurAvgCpu > b.BaseAvgCpu * 1.5;
GO


/*------------------------------------------------------------------------------
  BLOCKING, IO, CAPACITY, INDEXES, SECURITY - all per database
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_BlockingSummary
AS
SELECT  ServerName, DatabaseName, HeadBlockerSessionId,
        Incidents       = COUNT(*),
        DistinctVictims = COUNT(DISTINCT BlockedSessionId),
        MaxWaitSec      = CAST(MAX(WaitDurationMs) / 1000.0 AS decimal(19,2)),
        TotalWaitSec    = CAST(SUM(WaitDurationMs) / 1000.0 AS decimal(19,2)),
        MaxChainDepth   = MAX(ChainDepth),
        FirstSeenUtc    = MIN(SnapshotUtc),
        LastSeenUtc     = MAX(SnapshotUtc),
        BlockerLogin    = MIN(BlockerLogin),
        BlockerProgram  = MIN(BlockerProgram),
        BlockerHost     = MIN(BlockerHost),
        BlockerStatus   = MIN(BlockerStatus),
        BlockerSql      = MIN(BlockerSql),
        SampleVictimSql = MIN(BlockedSql),
        WaitTypes       = STRING_AGG(CONVERT(nvarchar(60), WaitType), ', ') WITHIN GROUP (ORDER BY WaitType)
FROM    core.BlockingChain
WHERE   SnapshotUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, HeadBlockerSessionId;
GO

CREATE OR ALTER VIEW core.vw_IoLatency
AS
WITH seq AS
(
    SELECT  ServerName, DatabaseName, SnapshotUtc, FileId, FileName, TypeDesc,
            NumReads, IoStallReadMs, NumWrites, IoStallWriteMs, BytesRead, BytesWritten,
            PrevUtc        = LAG(SnapshotUtc)    OVER (PARTITION BY ServerName, DatabaseName, FileId ORDER BY SnapshotUtc),
            PrevReads      = LAG(NumReads)       OVER (PARTITION BY ServerName, DatabaseName, FileId ORDER BY SnapshotUtc),
            PrevReadStall  = LAG(IoStallReadMs)  OVER (PARTITION BY ServerName, DatabaseName, FileId ORDER BY SnapshotUtc),
            PrevWrites     = LAG(NumWrites)      OVER (PARTITION BY ServerName, DatabaseName, FileId ORDER BY SnapshotUtc),
            PrevWriteStall = LAG(IoStallWriteMs) OVER (PARTITION BY ServerName, DatabaseName, FileId ORDER BY SnapshotUtc),
            PrevBytesRead  = LAG(BytesRead)      OVER (PARTITION BY ServerName, DatabaseName, FileId ORDER BY SnapshotUtc),
            PrevBytesWrite = LAG(BytesWritten)   OVER (PARTITION BY ServerName, DatabaseName, FileId ORDER BY SnapshotUtc)
    FROM    core.IoFileStats
)
SELECT  ServerName, DatabaseName, SnapshotUtc, FileId, FileName, TypeDesc,
        ReadLatencyMs  = CAST((IoStallReadMs  - PrevReadStall)  * 1.0 / NULLIF(NumReads  - PrevReads,  0) AS decimal(19,2)),
        WriteLatencyMs = CAST((IoStallWriteMs - PrevWriteStall) * 1.0 / NULLIF(NumWrites - PrevWrites, 0) AS decimal(19,2)),
        ReadMBPerSec   = CAST((BytesRead    - PrevBytesRead)  / 1048576.0
                              / NULLIF(DATEDIFF(SECOND, PrevUtc, SnapshotUtc), 0) AS decimal(19,2)),
        WriteMBPerSec  = CAST((BytesWritten - PrevBytesWrite) / 1048576.0
                              / NULLIF(DATEDIFF(SECOND, PrevUtc, SnapshotUtc), 0) AS decimal(19,2))
FROM    seq
WHERE   PrevUtc IS NOT NULL AND NumReads >= PrevReads AND NumWrites >= PrevWrites;
GO

/*------------------------------------------------------------------------------
  CAPACITY FORECAST - same guard rails as the embedded edition.
  DaysUntilFull is NULL, never a bogus huge number, when growth is flat or the
  wall is beyond the horizon. Clamping happens BEFORE the int cast and the
  DATEADD, both of which overflow on a near-idle database.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_CapacityForecast
AS
WITH samples AS
(
    SELECT  ServerName, DatabaseName, SnapshotUtc, MaxSizeMB,
            X = CAST(DATEDIFF(HOUR, MIN(SnapshotUtc) OVER (PARTITION BY ServerName, DatabaseName), SnapshotUtc) AS float),
            Y = CAST(UsedMB AS float)
    FROM    core.DatabaseSpace
    WHERE   SnapshotUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
),
agg AS
(
    SELECT  ServerName, DatabaseName,
            N = COUNT_BIG(*), SumX = SUM(X), SumY = SUM(Y), SumXY = SUM(X*Y), SumXX = SUM(X*X),
            MaxSizeMB = MAX(MaxSizeMB),
            LastUtc   = MAX(SnapshotUtc),
            FirstUtc  = MIN(SnapshotUtc)
    FROM    samples
    GROUP BY ServerName, DatabaseName
    HAVING  COUNT_BIG(*) >= 2
),
calc AS
(
    SELECT  a.*,
            CurrentMB = (SELECT TOP (1) s2.Y FROM samples s2
                         WHERE s2.ServerName = a.ServerName AND s2.DatabaseName = a.DatabaseName
                         ORDER BY s2.SnapshotUtc DESC),
            Slope = CASE WHEN (a.N * a.SumXX - a.SumX * a.SumX) <> 0
                         THEN (a.N * a.SumXY - a.SumX * a.SumY) / (a.N * a.SumXX - a.SumX * a.SumX) END
    FROM    agg AS a
)
SELECT  c.ServerName, c.DatabaseName,
        CurrentUsedMB  = CAST(c.CurrentMB AS decimal(19,2)),
        MaxSizeMB      = CAST(c.MaxSizeMB AS decimal(19,2)),
        PctUsed        = CAST(c.CurrentMB * 100.0 / NULLIF(c.MaxSizeMB, 0) AS decimal(9,2)),
        GrowthMBPerDay = CAST(c.Slope * 24 AS decimal(19,3)),
        DaysUntilFull  = CASE WHEN d.DaysRaw IS NOT NULL AND d.DaysRaw <= 3650 THEN CAST(d.DaysRaw AS int) END,
        ProjectedFullUtc = CASE WHEN d.DaysRaw IS NOT NULL AND d.DaysRaw <= 3650
                                THEN DATEADD(DAY, CAST(d.DaysRaw AS int), SYSUTCDATETIME()) END,
        Verdict = CASE
            WHEN c.MaxSizeMB IS NULL OR c.MaxSizeMB <= 0 THEN 'Unknown MAXSIZE'
            WHEN c.CurrentMB >= c.MaxSizeMB              THEN 'ALREADY FULL'
            WHEN c.Slope * 24 <= 0                       THEN 'Flat or shrinking - no wall'
            WHEN d.DaysRaw IS NULL OR d.DaysRaw > 3650   THEN 'No wall within 10 years'
            WHEN d.DaysRaw <= 7                          THEN 'CRITICAL - under a week'
            WHEN d.DaysRaw <= 30                         THEN 'WARNING - under a month'
            WHEN d.DaysRaw <= 90                         THEN 'Plan a resize this quarter'
            ELSE 'Comfortable' END,
        SampleCount = c.N,
        Confidence  = CASE WHEN c.N >= 20 THEN 'High' WHEN c.N >= 7 THEN 'Medium' ELSE 'Low' END,
        WindowStartUtc = c.FirstUtc, WindowEndUtc = c.LastUtc
FROM    calc AS c
CROSS APPLY (SELECT DaysRaw = CASE WHEN c.Slope * 24 > 0 AND (c.MaxSizeMB - c.CurrentMB) > 0
                                   THEN (c.MaxSizeMB - c.CurrentMB) / (c.Slope * 24) END) AS d;
GO

CREATE OR ALTER VIEW core.vw_UnusedIndexes
AS
WITH latest AS
(
    SELECT ServerName, DatabaseName, MaxSnap = MAX(SnapshotDate)
    FROM   core.IndexUsage GROUP BY ServerName, DatabaseName
)
SELECT  u.ServerName, u.DatabaseName, u.SchemaName, u.TableName, u.IndexName,
        u.IndexType, u.KeyColumns, u.IncludedColumns, u.SizeMB, u.RowCountEst,
        TotalReads = u.UserSeeks + u.UserScans + u.UserLookups,
        u.UserSeeks, u.UserScans, u.UserLookups, u.UserUpdates,
        Verdict = CASE
            WHEN u.IsPrimaryKey = 1 OR u.IsUnique = 1 THEN 'KEEP - enforces a constraint'
            WHEN (u.UserSeeks + u.UserScans + u.UserLookups) = 0 AND u.UserUpdates > 1000
                 THEN 'DROP CANDIDATE - never read, maintained on every write'
            WHEN (u.UserSeeks + u.UserScans + u.UserLookups) = 0 THEN 'Unused in the observed window'
            WHEN u.UserUpdates > (u.UserSeeks + u.UserScans + u.UserLookups) * 10
                 THEN 'Write-heavy - 10x more maintained than read'
            ELSE 'In use' END,
        DropStatement = N'DROP INDEX ' + QUOTENAME(u.IndexName) + N' ON '
                        + QUOTENAME(u.SchemaName) + N'.' + QUOTENAME(u.TableName) + N';'
FROM    core.IndexUsage AS u
JOIN    latest AS l ON l.ServerName = u.ServerName AND l.DatabaseName = u.DatabaseName
                   AND l.MaxSnap = u.SnapshotDate
WHERE   u.IndexName <> N'(heap)';
GO

CREATE OR ALTER VIEW core.vw_MissingIndexTop
AS
WITH latest AS
(
    SELECT ServerName, DatabaseName, MaxSnap = MAX(SnapshotDate)
    FROM   core.MissingIndex GROUP BY ServerName, DatabaseName
)
SELECT  m.ServerName, m.DatabaseName, m.SchemaName, m.TableName,
        m.EqualityColumns, m.InequalityColumns, m.IncludedColumns,
        m.UserSeeks,
        AvgUserImpact = CAST(m.AvgUserImpact AS decimal(9,2)),
        ImpactScore   = CAST(m.ImpactScore   AS decimal(19,2)),
        m.CreateStatement
FROM    core.MissingIndex AS m
JOIN    latest AS l ON l.ServerName = m.ServerName AND l.DatabaseName = m.DatabaseName
                   AND l.MaxSnap = m.SnapshotDate;
GO

CREATE OR ALTER VIEW core.vw_FragmentationWork
AS
WITH latest AS
(
    SELECT ServerName, DatabaseName, MaxSnap = MAX(SnapshotDate)
    FROM   core.IndexFragmentation GROUP BY ServerName, DatabaseName
)
SELECT  f.ServerName, f.DatabaseName, f.SchemaName, f.TableName, f.IndexName,
        f.AvgFragmentationPct, f.PageCount, f.RecommendedAction,
        EstimatedSizeMB = CAST(f.PageCount * 8.0 / 1024 AS decimal(19,2)),
        MaintenanceStatement = CASE f.RecommendedAction
            WHEN 'REBUILD'    THEN N'ALTER INDEX ' + QUOTENAME(f.IndexName) + N' ON '
                                   + QUOTENAME(f.SchemaName) + N'.' + QUOTENAME(f.TableName)
                                   + N' REBUILD WITH (ONLINE = ON, RESUMABLE = ON, MAXDOP = 2);'
            WHEN 'REORGANIZE' THEN N'ALTER INDEX ' + QUOTENAME(f.IndexName) + N' ON '
                                   + QUOTENAME(f.SchemaName) + N'.' + QUOTENAME(f.TableName) + N' REORGANIZE;'
            ELSE NULL END
FROM    core.IndexFragmentation AS f
JOIN    latest AS l ON l.ServerName = f.ServerName AND l.DatabaseName = f.DatabaseName
                   AND l.MaxSnap = f.SnapshotDate
WHERE   f.RecommendedAction <> 'NONE';
GO

CREATE OR ALTER VIEW core.vw_SecurityDrift
AS
WITH snaps AS
(
    SELECT ServerName, DatabaseName, SnapshotDate,
           rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY SnapshotDate DESC)
    FROM   (SELECT DISTINCT ServerName, DatabaseName, SnapshotDate FROM core.SecurityPrincipal) AS d
),
cur  AS (SELECT p.* FROM core.SecurityPrincipal p JOIN snaps s
         ON s.ServerName=p.ServerName AND s.DatabaseName=p.DatabaseName AND s.SnapshotDate=p.SnapshotDate AND s.rn=1),
prev AS (SELECT p.* FROM core.SecurityPrincipal p JOIN snaps s
         ON s.ServerName=p.ServerName AND s.DatabaseName=p.DatabaseName AND s.SnapshotDate=p.SnapshotDate AND s.rn=2)
SELECT  ChangeType = 'PRINCIPAL ADDED', Severity = 'Warning',
        c.ServerName, c.DatabaseName, Subject = c.PrincipalName,
        Detail = CONCAT('type=', c.TypeDesc, ', auth=', c.AuthType,
                        ', roles=', ISNULL(c.RoleMemberships, '(none)')),
        DetectedDate = c.SnapshotDate
FROM    cur AS c
LEFT JOIN prev AS p ON p.ServerName=c.ServerName AND p.DatabaseName=c.DatabaseName
                   AND p.PrincipalName=c.PrincipalName
WHERE   p.PrincipalName IS NULL
  AND   EXISTS (SELECT 1 FROM prev x WHERE x.ServerName=c.ServerName AND x.DatabaseName=c.DatabaseName)

UNION ALL
SELECT  'PRINCIPAL REMOVED', 'Warning', p.ServerName, p.DatabaseName, p.PrincipalName,
        CONCAT('type=', p.TypeDesc, ', roles=', ISNULL(p.RoleMemberships, '(none)')), p.SnapshotDate
FROM    prev AS p
LEFT JOIN cur AS c ON c.ServerName=p.ServerName AND c.DatabaseName=p.DatabaseName
                  AND c.PrincipalName=p.PrincipalName
WHERE   c.PrincipalName IS NULL

UNION ALL
SELECT  'ROLE MEMBERSHIP CHANGED',
        CASE WHEN ISNULL(c.RoleMemberships,'') LIKE '%db_owner%'
              AND ISNULL(p.RoleMemberships,'') NOT LIKE '%db_owner%' THEN 'Critical' ELSE 'Warning' END,
        c.ServerName, c.DatabaseName, c.PrincipalName,
        CONCAT('was [', ISNULL(p.RoleMemberships,'(none)'), '] now [', ISNULL(c.RoleMemberships,'(none)'), ']'),
        c.SnapshotDate
FROM    cur AS c
JOIN    prev AS p ON p.ServerName=c.ServerName AND p.DatabaseName=c.DatabaseName
                 AND p.PrincipalName=c.PrincipalName
WHERE   ISNULL(c.RoleMemberships, N'') <> ISNULL(p.RoleMemberships, N'');
GO

CREATE OR ALTER VIEW core.vw_ErrorSummary
AS
SELECT  ServerName, DatabaseName, ErrorNumber,
        Severity     = MAX(Severity),
        Occurrences  = COUNT(*),
        FirstSeenUtc = MIN(EventTimeUtc),
        LastSeenUtc  = MAX(EventTimeUtc),
        SampleMessage= MIN(Message),
        SampleSql    = MIN(SqlText),
        TopApp       = MIN(ProgramName)
FROM    core.ErrorEvent
WHERE   EventTimeUtc >= DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, ErrorNumber;
GO

CREATE OR ALTER VIEW core.vw_DeadlockSummary
AS
SELECT  ServerName, DatabaseName,
        DayUtc    = CAST(EventTimeUtc AS date),
        Deadlocks = COUNT(*),
        MaxProcesses = MAX(ProcessCount),
        FirstUtc  = MIN(EventTimeUtc),
        LastUtc   = MAX(EventTimeUtc)
FROM    core.Deadlock
WHERE   EventTimeUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, CAST(EventTimeUtc AS date);
GO

CREATE OR ALTER VIEW core.vw_OpenAlerts
AS
SELECT  a.AlertId, a.ServerName, a.DatabaseName, a.RaisedUtc, a.AlertCode,
        a.Severity, a.Category, a.Metric, a.ObservedValue, a.ThresholdValue,
        a.Message, a.Detail,
        AgeMinutes = DATEDIFF(MINUTE, a.RaisedUtc, SYSUTCDATETIME())
FROM    core.AlertHistory AS a
WHERE   a.ResolvedUtc IS NULL;
GO


/*==============================================================================
  THE FLEET VIEW - one row per database. This is the query the embedded edition
  could never write.
==============================================================================*/
CREATE OR ALTER VIEW core.vw_FleetScorecard
AS
WITH res AS
(
    SELECT  ServerName, DatabaseName,
            AvgCpu   = AVG(AvgCpuPct),      PeakCpu = MAX(AvgCpuPct),
            AvgIo    = AVG(AvgDataIoPct),   PeakIo  = MAX(AvgDataIoPct),
            AvgLog   = AVG(AvgLogWritePct), PeakLog = MAX(AvgLogWritePct),
            AvgMem   = AVG(AvgMemoryPct),
            PeakWrk  = MAX(MaxWorkerPct),   PeakSes = MAX(MaxSessionPct)
    FROM    core.ResourceUsage
    WHERE   EndTimeUtc >= DATEADD(HOUR, -1, SYSUTCDATETIME())
    GROUP BY ServerName, DatabaseName
),
spc AS
(
    SELECT  s.ServerName, s.DatabaseName, s.PctOfMaxSize, s.UsedMB, s.MaxSizeMB,
            s.ServiceObjective, s.Edition
    FROM    core.DatabaseSpace AS s
    JOIN   (SELECT ServerName, DatabaseName, MaxUtc = MAX(SnapshotUtc)
            FROM core.DatabaseSpace GROUP BY ServerName, DatabaseName) AS m
         ON m.ServerName = s.ServerName AND m.DatabaseName = s.DatabaseName AND m.MaxUtc = s.SnapshotUtc
),
alr AS
(
    SELECT  ServerName, DatabaseName,
            CriticalCount = SUM(CASE WHEN Severity = 'Critical' THEN 1 ELSE 0 END),
            WarningCount  = SUM(CASE WHEN Severity = 'Warning'  THEN 1 ELSE 0 END)
    FROM    core.AlertHistory WHERE ResolvedUtc IS NULL
    GROUP BY ServerName, DatabaseName
),
blk AS
(
    SELECT  ServerName, DatabaseName,
            BlockingChains = COUNT(DISTINCT HeadBlockerSessionId),
            WorstBlockSec  = CAST(MAX(WaitDurationMs) / 1000.0 AS decimal(19,2))
    FROM    core.BlockingChain
    WHERE   SnapshotUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    GROUP BY ServerName, DatabaseName
)
SELECT  t.ServerName, t.DatabaseName, t.Environment, t.Owner, t.Criticality, t.IsVendorOwned,
        Edition          = spc.Edition,
        ServiceObjective = spc.ServiceObjective,
        AvgCpuPct      = CAST(res.AvgCpu  AS decimal(9,2)),
        AvgDataIoPct   = CAST(res.AvgIo   AS decimal(9,2)),
        AvgLogWritePct = CAST(res.AvgLog  AS decimal(9,2)),
        AvgMemoryPct   = CAST(res.AvgMem  AS decimal(9,2)),
        PeakWorkerPct  = CAST(res.PeakWrk AS decimal(9,2)),
        PeakSessionPct = CAST(res.PeakSes AS decimal(9,2)),
        StoragePct     = CAST(spc.PctOfMaxSize AS decimal(9,2)),
        UsedMB         = spc.UsedMB,
        MaxSizeMB      = spc.MaxSizeMB,
        CriticalAlerts = ISNULL(alr.CriticalCount, 0),
        WarningAlerts  = ISNULL(alr.WarningCount, 0),
        BlockingChains = ISNULL(blk.BlockingChains, 0),
        WorstBlockSec  = blk.WorstBlockSec,
        DaysUntilFull  = fc.DaysUntilFull,
        CapacityVerdict= fc.Verdict,
        t.CollectionState,
        t.StaleTiers,
        t.LastAnyArrivalUtc,
        /* worst dimension across the window drives the score, so a database
           that is fine on CPU but 94% full is still flagged */
        PeakPercent = (SELECT MAX(v) FROM (VALUES (res.PeakCpu), (res.PeakLog), (res.PeakWrk),
                                                  (res.PeakSes), (spc.PctOfMaxSize)) AS x(v)),
        HealthScore = CASE
            WHEN t.CollectionState IN ('NEVER','CRITICAL') THEN 0
            WHEN (SELECT MAX(v) FROM (VALUES (res.PeakCpu),(res.PeakLog),(res.PeakWrk),
                                             (res.PeakSes),(spc.PctOfMaxSize)) AS x(v)) >= 95 THEN 0
            WHEN (SELECT MAX(v) FROM (VALUES (res.PeakCpu),(res.PeakLog),(res.PeakWrk),
                                             (res.PeakSes),(spc.PctOfMaxSize)) AS x(v)) >= 85 THEN 25
            WHEN (SELECT MAX(v) FROM (VALUES (res.PeakCpu),(res.PeakLog),(res.PeakWrk),
                                             (res.PeakSes),(spc.PctOfMaxSize)) AS x(v)) >= 70 THEN 50
            WHEN (SELECT MAX(v) FROM (VALUES (res.PeakCpu),(res.PeakLog),(res.PeakWrk),
                                             (res.PeakSes),(spc.PctOfMaxSize)) AS x(v)) >= 50 THEN 75
            ELSE 100 END,
        WorstDimension = CASE
            WHEN t.CollectionState IN ('NEVER','CRITICAL') THEN 'NOT REPORTING'
            WHEN res.PeakWrk  >= ISNULL(res.PeakCpu,0) AND res.PeakWrk >= ISNULL(spc.PctOfMaxSize,0) THEN 'WORKERS'
            WHEN res.PeakSes  >= ISNULL(res.PeakCpu,0) AND res.PeakSes >= ISNULL(spc.PctOfMaxSize,0) THEN 'SESSIONS'
            WHEN spc.PctOfMaxSize >= ISNULL(res.PeakCpu,0) THEN 'STORAGE'
            WHEN res.PeakLog  >= ISNULL(res.PeakCpu,0) THEN 'LOG WRITE'
            WHEN res.PeakCpu  IS NOT NULL THEN 'CPU'
            ELSE 'No data' END
FROM    core.vw_TargetStatus AS t
LEFT JOIN res ON res.ServerName = t.ServerName AND res.DatabaseName = t.DatabaseName
LEFT JOIN spc ON spc.ServerName = t.ServerName AND spc.DatabaseName = t.DatabaseName
LEFT JOIN alr ON alr.ServerName = t.ServerName AND alr.DatabaseName = t.DatabaseName
LEFT JOIN blk ON blk.ServerName = t.ServerName AND blk.DatabaseName = t.DatabaseName
LEFT JOIN core.vw_CapacityForecast AS fc
       ON fc.ServerName = t.ServerName AND fc.DatabaseName = t.DatabaseName;
GO

/*------------------------------------------------------------------------------
  ESTATE ROLL-UP - one row. The number you put on a wall display.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW core.vw_FleetSummary
AS
SELECT  Databases        = COUNT(*),
        Servers          = COUNT(DISTINCT ServerName),
        VendorDatabases  = SUM(CASE WHEN IsVendorOwned = 1 THEN 1 ELSE 0 END),
        CriticalAlerts   = SUM(CriticalAlerts),
        WarningAlerts    = SUM(WarningAlerts),
        AtRisk           = SUM(CASE WHEN HealthScore <= 50 THEN 1 ELSE 0 END),
        NotReporting     = SUM(CASE WHEN CollectionState IN ('NEVER','CRITICAL') THEN 1 ELSE 0 END),
        BlockingChains   = SUM(BlockingChains),
        TotalStorageGB   = CAST(SUM(UsedMB) / 1024.0 AS decimal(19,1)),
        NearestWallDays  = MIN(CASE WHEN DaysUntilFull <= 365 THEN DaysUntilFull END),
        NearestWallDb    = (SELECT TOP (1) DatabaseName FROM core.vw_FleetScorecard
                            WHERE DaysUntilFull IS NOT NULL AND DaysUntilFull <= 365
                            ORDER BY DaysUntilFull)
FROM    core.vw_FleetScorecard;
GO

PRINT '=== analysis views deployed ===';
GO
