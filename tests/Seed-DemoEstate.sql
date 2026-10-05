/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : tests/Seed-DemoEstate.sql
  Run in : the CENTRAL repository database

  WHAT THIS IS
  ------------
  A synthetic estate - 2 servers, 6 databases - written straight into core.*
  so every panel of the dashboard has something to render and every health
  state is represented. For demonstrations and screenshots, and for exercising
  the views and the alert engine without waiting days for real data.

  ------------------------------------------------------------------------------
  SAFETY - READ THIS
  ------------------------------------------------------------------------------
  Every demo server name begins with 'demo-'. That prefix is the ONLY thing
  tests/Remove-DemoEstate.sql uses to find and delete this data, so demo rows
  can always be removed surgically and real monitoring data can never be caught
  by the cleanup.

  This script writes to core.* and cfg.Target only. It does NOT touch staging,
  the jobs schema, any Azure resource, or any monitored database. It is
  idempotent: it removes its own previous output before re-seeding.

  AFTER SEEDING, run the real alert engine so the alerts are genuine rather
  than hand-written:

        EXEC core.usp_EvaluateAlerts;

  THE ESTATE
  ------------------------------------------------------------------------------
    demo-sql-prod-weu   OrdersDB      CRITICAL      CPU pegged, storage 96%,
                                                    blocking, deadlocks, errors,
                                                    query regression, stopped XE
                        BillingDB     WARNING       storage 82%, lock waits,
                                                    missing indexes, security drift
                        CatalogDB     HEALTHY       the control case
                        ArchiveDB     NOT REPORTING collection stopped 9 h ago

    demo-sql-dr-neu     ReplicaDB     WARNING       IO latency, log at 88% held
                                                    by an open transaction
                        SandboxDB     HEALTHY       but forecast to fill in ~18 d
==============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*------------------------------------------------------------------------------
  0. Remove any previous demo seed so this script can be re-run safely.
     Dynamic over every table carrying a ServerName column, so a table added
     later cannot be silently missed.
------------------------------------------------------------------------------*/
DECLARE @t sysname, @s sysname, @sql nvarchar(max), @wiped bigint = 0;

DECLARE cw CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.name, t.name
    FROM   sys.tables  AS t
    JOIN   sys.schemas AS s ON s.schema_id = t.schema_id
    JOIN   sys.columns AS c ON c.object_id = t.object_id AND c.name = 'ServerName'
    WHERE  s.name IN ('core', 'cfg');
OPEN cw; FETCH NEXT FROM cw INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'DELETE FROM ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
             + N' WHERE ServerName LIKE ''demo-%'';';
    EXEC sys.sp_executesql @sql;
    SET @wiped += @@ROWCOUNT;
    FETCH NEXT FROM cw INTO @s, @t;
END
CLOSE cw; DEALLOCATE cw;
PRINT 'cleared ' + CAST(@wiped AS varchar(20)) + ' pre-existing demo row(s)';
GO


/*==============================================================================
  1. THE ESTATE DEFINITION
  Every per-database characteristic lives here, so the generators below stay
  simple and the profiles are easy to re-tune.
==============================================================================*/
DECLARE @Now datetime2(3) = SYSUTCDATETIME();

DECLARE @est TABLE (
    Srv sysname, Db sysname, Slo varchar(32), Edition varchar(32),
    CpuBase decimal(9,2), IoBase decimal(9,2), LogBase decimal(9,2),
    MemBase decimal(9,2), WrkBase decimal(9,2),
    MaxMB decimal(19,2), UsedMB decimal(19,2), GrowthMBPerDay decimal(19,2),
    LogPct decimal(9,2), StaleHours int);

INSERT @est VALUES
 ('demo-sql-prod-weu.database.windows.net','OrdersDB', 'P2','Premium', 92.0,74.0,61.0,88.0,79.0, 512000.0,491520.0, 900.0, 71.0, 0),
 ('demo-sql-prod-weu.database.windows.net','BillingDB','S4','Standard',68.0,41.0,33.0,62.0,44.0, 256000.0,209920.0, 420.0, 54.0, 0),
 ('demo-sql-prod-weu.database.windows.net','CatalogDB','S2','Standard',14.0, 9.0, 6.0,31.0,11.0, 128000.0, 28160.0,  25.0, 12.0, 0),
 ('demo-sql-prod-weu.database.windows.net','ArchiveDB','S1','Standard', 7.0, 4.0, 3.0,22.0, 6.0, 128000.0, 61440.0,   5.0,  9.0, 9),
 ('demo-sql-dr-neu.database.windows.net',  'ReplicaDB','P1','Premium', 37.0,88.0,79.0,58.0,33.0, 256000.0,141312.0, 180.0, 88.0, 0),
 ('demo-sql-dr-neu.database.windows.net',  'SandboxDB','S2','Standard',22.0,17.0,12.0,35.0,18.0,  51200.0, 34816.0, 820.0, 19.0, 0);

/*-- target registry ---------------------------------------------------------*/
INSERT cfg.Target (ServerName, DatabaseName, Environment, IsEnabled, Notes, FirstSeenUtc, LastSeenUtc)
SELECT e.Srv, e.Db,
       CASE WHEN e.Srv LIKE '%prod%' THEN 'Production' ELSE 'DR' END,
       1, 'DEMO SEED - remove with tests\Remove-DemoEstate.sql',
       DATEADD(DAY, -30, @Now),
       CASE WHEN e.StaleHours > 0 THEN DATEADD(HOUR, -e.StaleHours, @Now) ELSE @Now END
FROM @est AS e;

/*------------------------------------------------------------------------------
  Resource usage - 24 h at 15-minute granularity. This drives the sparklines and
  every CPU / IO / log / memory figure on the fleet scorecard.

  Shape rather than noise: a working-hours ramp plus a deterministic wobble, so
  the charts look like a real day rather than a flat line. ArchiveDB simply stops
  producing rows 9 hours ago - that absence is what makes it NOT REPORTING.
------------------------------------------------------------------------------*/
;WITH n AS (
    SELECT TOP (96) rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
    FROM sys.all_objects)
INSERT core.ResourceUsage
    (ServerName, DatabaseName, EndTimeUtc, AvgCpuPct, AvgDataIoPct, AvgLogWritePct,
     AvgMemoryPct, MaxWorkerPct, MaxSessionPct, AvgInstanceCpuPct, DtuLimit, LandedUtc)
SELECT  e.Srv, e.Db,
        DATEADD(MINUTE, -15 * n.rn, @Now),
        ROUND(e.CpuBase * (0.72 + 0.28 * (1 - ABS(48 - n.rn) / 48.0))
             + (ABS(CHECKSUM(e.Db, n.rn)) % 900) / 100.0, 2),
        ROUND(e.IoBase  * (0.70 + 0.30 * (1 - ABS(48 - n.rn) / 48.0))
             + (ABS(CHECKSUM(e.Db, n.rn, 7)) % 700) / 100.0, 2),
        ROUND(e.LogBase * (0.75 + 0.25 * (1 - ABS(48 - n.rn) / 48.0))
             + (ABS(CHECKSUM(e.Db, n.rn, 13)) % 500) / 100.0, 2),
        ROUND(e.MemBase + (ABS(CHECKSUM(e.Db, n.rn, 23)) % 400) / 100.0, 2),
        ROUND(e.WrkBase * (0.70 + 0.30 * (1 - ABS(48 - n.rn) / 48.0))
             + (ABS(CHECKSUM(e.Db, n.rn, 31)) % 600) / 100.0, 2),
        ROUND(e.WrkBase * 0.6 + (ABS(CHECKSUM(e.Db, n.rn, 37)) % 500) / 100.0, 2),
        ROUND(e.CpuBase * 0.8 + (ABS(CHECKSUM(e.Db, n.rn, 41)) % 600) / 100.0, 2),
        CASE e.Slo WHEN 'P2' THEN 250 WHEN 'P1' THEN 125
                   WHEN 'S4' THEN 200 WHEN 'S2' THEN 50 ELSE 20 END,
        DATEADD(MINUTE, -15 * n.rn, @Now)
FROM    @est AS e
CROSS JOIN n
WHERE   NOT (e.StaleHours > 0 AND n.rn < (e.StaleHours * 4));

/*------------------------------------------------------------------------------
  Database space - 14 daily points, because core.vw_CapacityForecast fits a
  slope across them. SandboxDB grows fast enough to be forecast full in roughly
  18 days, which is what lights up the "runs out of space" tile.
------------------------------------------------------------------------------*/
;WITH d AS (
    SELECT TOP (14) rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
    FROM sys.all_objects)
INSERT core.DatabaseSpace
    (ServerName, DatabaseName, SnapshotUtc, AllocatedMB, UsedMB, MaxSizeMB,
     PctOfMaxSize, DataUsedMB, IndexUsedMB, ServiceObjective, Edition)
SELECT  e.Srv, e.Db,
        DATEADD(DAY, -d.rn, @Now),
        ROUND((e.UsedMB - (e.GrowthMBPerDay * d.rn)) * 1.08, 2),
        ROUND(e.UsedMB - (e.GrowthMBPerDay * d.rn), 2),
        e.MaxMB,
        ROUND((e.UsedMB - (e.GrowthMBPerDay * d.rn)) * 100.0 / e.MaxMB, 2),
        ROUND((e.UsedMB - (e.GrowthMBPerDay * d.rn)) * 0.76, 2),
        ROUND((e.UsedMB - (e.GrowthMBPerDay * d.rn)) * 0.24, 2),
        e.Slo, e.Edition
FROM    @est AS e CROSS JOIN d
WHERE   e.UsedMB - (e.GrowthMBPerDay * d.rn) > 0;

/*------------------------------------------------------------------------------
  Log space and tempdb. ReplicaDB carries an open transaction holding log
  truncation - the reuse-wait reason is the actionable part, not the percentage.
------------------------------------------------------------------------------*/
;WITH h AS (SELECT TOP (8) rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 FROM sys.all_objects)
INSERT core.LogSpace
    (ServerName, DatabaseName, SnapshotUtc, TotalLogSizeMB, UsedLogSpaceMB,
     UsedLogSpacePct, LogReuseWaitDesc, OldestTranBeginUtc, OldestTranSessionId)
SELECT  e.Srv, e.Db, DATEADD(HOUR, -3 * h.rn, @Now),
        ROUND(e.MaxMB * 0.25, 2),
        ROUND(e.MaxMB * 0.25 * (e.LogPct - h.rn) / 100.0, 2),
        e.LogPct - h.rn,
        CASE WHEN e.Db = 'ReplicaDB' THEN 'ACTIVE_TRANSACTION'
             WHEN e.Db = 'OrdersDB'  THEN 'LOG_BACKUP' ELSE 'NOTHING' END,
        CASE WHEN e.Db = 'ReplicaDB' THEN DATEADD(HOUR, -7, @Now) END,
        CASE WHEN e.Db = 'ReplicaDB' THEN CAST(219 AS smallint) END
FROM    @est AS e CROSS JOIN h
WHERE   e.StaleHours = 0;

INSERT core.TempDbUsage
    (ServerName, DatabaseName, SnapshotUtc, TotalMB, AllocatedMB, PctUsed,
     UserObjectsMB, InternalObjectsMB, VersionStoreMB)
SELECT  e.Srv, e.Db, @Now, 32768.0,
        ROUND(32768.0 * e.CpuBase / 180.0, 2),
        ROUND(e.CpuBase / 1.8, 2),
        ROUND(32768.0 * e.CpuBase / 420.0, 2),
        ROUND(32768.0 * e.CpuBase / 640.0, 2),
        CASE WHEN e.Db = 'ReplicaDB' THEN 4096.0 ELSE ROUND(32768.0 * e.CpuBase / 2400.0, 2) END
FROM    @est AS e WHERE e.StaleHours = 0;

PRINT 'resource usage, space, log and tempdb seeded';
GO


/*==============================================================================
  2. WAITS AND QUERIES
  Both are CUMULATIVE feeds, so each needs at least two snapshots - the views
  difference them. One snapshot would render nothing at all.
==============================================================================*/
DECLARE @Now datetime2(3) = SYSUTCDATETIME();

DECLARE @db TABLE (Srv sysname, Db sysname, CpuBase decimal(9,2));
INSERT @db
SELECT ServerName, DatabaseName,
       CASE DatabaseName WHEN 'OrdersDB' THEN 92 WHEN 'BillingDB' THEN 68
                         WHEN 'ReplicaDB' THEN 37 WHEN 'SandboxDB' THEN 22
                         ELSE 14 END
FROM   cfg.Target
WHERE  ServerName LIKE 'demo-%' AND DatabaseName <> 'ArchiveDB';

DECLARE @waits TABLE (WaitType nvarchar(60), Weight decimal(9,3));
INSERT @waits VALUES
 ('LCK_M_X', 4.20), ('PAGEIOLATCH_SH', 3.10), ('WRITELOG', 2.60),
 ('SOS_SCHEDULER_YIELD', 2.10), ('CXPACKET', 1.70), ('RESOURCE_SEMAPHORE', 1.30),
 ('ASYNC_NETWORK_IO', 0.90), ('PAGELATCH_EX', 0.70), ('LCK_M_U', 0.55),
 ('THREADPOOL', 0.35), ('HADR_SYNC_COMMIT', 0.25), ('BACKUPIO', 0.15);

INSERT core.WaitStats
    (ServerName, DatabaseName, SnapshotUtc, WaitType, WaitingTasksCount,
     WaitTimeMs, MaxWaitTimeMs, SignalWaitTimeMs)
SELECT  d.Srv, d.Db, DATEADD(MINUTE, -30 * s.rn, @Now), w.WaitType,
        CAST(1200 * w.Weight * d.CpuBase / 30 * (3 - s.rn) AS bigint),
        CAST(9000 * w.Weight * d.CpuBase / 20 * (3 - s.rn) AS bigint),
        CAST(260 * w.Weight AS bigint),
        CAST(420 * w.Weight * (3 - s.rn) AS bigint)
FROM    @db AS d CROSS JOIN @waits AS w
CROSS JOIN (VALUES (0),(1),(2)) AS s(rn);

DECLARE @q TABLE (Ix int, Txt nvarchar(400), Obj nvarchar(256), Weight decimal(9,3));
INSERT @q VALUES
 (1,'SELECT o.OrderId, o.PlacedUtc, c.Name FROM dbo.Orders o JOIN dbo.Customer c ON c.CustomerId = o.CustomerId WHERE o.Status = @p1 ORDER BY o.PlacedUtc DESC','dbo.usp_GetOpenOrders',5.40),
 (2,'UPDATE dbo.Inventory SET OnHand = OnHand - @qty WHERE Sku = @sku','dbo.usp_ReserveStock',3.90),
 (3,'SELECT SUM(Amount) FROM dbo.Ledger WHERE PostedUtc >= @from AND PostedUtc < @to','dbo.usp_PeriodTotals',3.10),
 (4,'SELECT TOP (500) * FROM dbo.AuditTrail WHERE EntityId = @id ORDER BY ChangedUtc DESC','(ad hoc)',2.30),
 (5,'INSERT dbo.EventLog (Source, Payload, CreatedUtc) VALUES (@s, @p, SYSUTCDATETIME())','dbo.usp_WriteEvent',1.60),
 (6,'DELETE TOP (5000) FROM dbo.Staging WHERE LoadedUtc < @cut','dbo.usp_PurgeOld',1.10),
 (7,'SELECT c.*, a.Line1, a.City FROM dbo.Customer c LEFT JOIN dbo.Address a ON a.CustomerId = c.CustomerId','(ad hoc)',0.80),
 (8,'EXEC dbo.usp_RebuildCache @Region = @r','dbo.usp_RebuildCache',0.50);

/*------------------------------------------------------------------------------
  Query stats - CUMULATIVE counters. core.vw_QueryStatsDelta differences
  consecutive snapshots, and core.vw_QueryRegression then compares two windows:
      baseline : older than 6 hours, within 7 days
      current  : the last 6 hours
  So four snapshots are needed, as two pairs - one pair in each window. Two
  snapshots half an hour apart (the obvious thing to seed) both land in the
  current window, leaving no baseline and no regression to find.

  OrdersDB queries 1 and 3 burn 4x the CPU per execution in the current window
  while running the same number of times. That is a regression, not a load
  increase, and it is the distinction the view exists to make.
------------------------------------------------------------------------------*/
DECLARE @snap TABLE (rn int, MinutesAgo int, InBaseline bit);
INSERT @snap VALUES (0, 4320, 1), (1, 4290, 1), (2, 40, 0), (3, 0, 0);

INSERT core.QueryStats
    (ServerName, DatabaseName, SnapshotUtc, QueryHash, QueryPlanHash, ExecutionCount,
     TotalWorkerTimeUs, TotalElapsedTimeUs, TotalLogicalReads, TotalLogicalWrites,
     TotalPhysicalReads, TotalRows, ObjectName, SampleSqlText)
SELECT  d.Srv, d.Db, DATEADD(MINUTE, -s.MinutesAgo, @Now),
        '0x' + CONVERT(varchar(16), CONVERT(binary(8), CAST(ABS(CHECKSUM(d.Db, q.Ix)) AS bigint)), 2),
        '0x' + CONVERT(varchar(16), CONVERT(binary(8), CAST(ABS(CHECKSUM(d.Db, q.Ix, 9)) AS bigint)), 2),
        /* cumulative: + baseline work after s0, + current work after s2 */
        CAST(100000 * q.Weight
             + CASE WHEN s.rn >= 1 THEN 9000 * q.Weight ELSE 0 END
             + CASE WHEN s.rn >= 3 THEN 9000 * q.Weight ELSE 0 END AS bigint),
        CAST(20000000 * q.Weight
             + CASE WHEN s.rn >= 1 THEN 1400000 * q.Weight * d.CpuBase / 40 ELSE 0 END
             + CASE WHEN s.rn >= 3 THEN 1400000 * q.Weight * d.CpuBase / 40
                         * CASE WHEN d.Db = 'OrdersDB' AND q.Ix IN (1,3) THEN 4.0 ELSE 1.0 END
                    ELSE 0 END AS bigint),
        CAST(38000000 * q.Weight
             + CASE WHEN s.rn >= 1 THEN 2600000 * q.Weight * d.CpuBase / 40 ELSE 0 END
             + CASE WHEN s.rn >= 3 THEN 2600000 * q.Weight * d.CpuBase / 40
                         * CASE WHEN d.Db = 'OrdersDB' AND q.Ix IN (1,3) THEN 4.0 ELSE 1.0 END
                    ELSE 0 END AS bigint),
        CAST(2000000 * q.Weight
             + CASE WHEN s.rn >= 1 THEN 260000 * q.Weight ELSE 0 END
             + CASE WHEN s.rn >= 3 THEN 260000 * q.Weight ELSE 0 END AS bigint),
        CAST(80000 * q.Weight
             + CASE WHEN s.rn >= 1 THEN 9000 * q.Weight ELSE 0 END
             + CASE WHEN s.rn >= 3 THEN 9000 * q.Weight ELSE 0 END AS bigint),
        CAST(40000 * q.Weight
             + CASE WHEN s.rn >= 1 THEN 4200 * q.Weight ELSE 0 END
             + CASE WHEN s.rn >= 3 THEN 4200 * q.Weight ELSE 0 END AS bigint),
        CAST(700000 * q.Weight
             + CASE WHEN s.rn >= 1 THEN 74000 * q.Weight ELSE 0 END
             + CASE WHEN s.rn >= 3 THEN 74000 * q.Weight ELSE 0 END AS bigint),
        q.Obj, q.Txt
FROM    @db AS d CROSS JOIN @q AS q CROSS JOIN @snap AS s;

/*------------------------------------------------------------------------------
  Query Store - two intervals. OrdersDB gets a genuine regression: the same
  query, a DIFFERENT plan id, roughly four times the duration. That plan change
  is what distinguishes "it got slower" from "it chose a worse plan", and it is
  what core.vw_QueryRegression is built to surface.

  THE INTERVAL SPACING MATTERS. The view compares the last 6 hours against the
  preceding 7 days. Two snapshots an hour apart both land inside the recent
  window, leaving no baseline, and the regression silently fails to appear.
  So the "before" interval is deliberately placed 3 days back.
------------------------------------------------------------------------------*/
INSERT core.QueryStoreTopQuery
    (ServerName, DatabaseName, SnapshotUtc, IntervalEndUtc, QueryId, PlanId, ObjectName,
     ExecutionCount, AvgDurationMs, AvgCpuMs, TotalCpuMs, AvgLogicalReads,
     AvgTempDbSpaceKb, AvgMemoryGrantKb, TopWaitCategory, QueryText)
SELECT  d.Srv, d.Db,
        CASE WHEN s.rn = 0 THEN @Now ELSE DATEADD(DAY, -3, @Now) END,
        CAST(CASE WHEN s.rn = 0 THEN @Now ELSE DATEADD(DAY, -3, @Now) END AS datetimeoffset(7)),
        q.Ix,
        CASE WHEN d.Db = 'OrdersDB' AND q.Ix IN (1,3) AND s.rn = 0
             THEN 9000 + q.Ix ELSE 1000 + q.Ix END,
        q.Obj,
        CAST(4200 * q.Weight AS bigint),
        CAST(CASE WHEN d.Db = 'OrdersDB' AND q.Ix IN (1,3) AND s.rn = 0
                  THEN 42.0 * q.Weight * 4.1 ELSE 42.0 * q.Weight END AS decimal(19,3)),
        CAST(CASE WHEN d.Db = 'OrdersDB' AND q.Ix IN (1,3) AND s.rn = 0
                  THEN 18.0 * q.Weight * 3.7 ELSE 18.0 * q.Weight END AS decimal(19,3)),
        CAST(18.0 * q.Weight * 4200 AS decimal(19,3)),
        CAST(900 * q.Weight AS decimal(19,3)),
        CAST(140 * q.Weight AS decimal(19,3)),
        CAST(2600 * q.Weight AS decimal(19,3)),
        CASE WHEN q.Ix IN (1,3) THEN 'Lock' WHEN q.Ix = 2 THEN 'BufferIO' ELSE 'CPU' END,
        q.Txt
FROM    @db AS d CROSS JOIN @q AS q CROSS JOIN (VALUES (0),(1)) AS s(rn);

PRINT 'waits, query stats and Query Store seeded';
GO


/*==============================================================================
  3. BLOCKING, DEADLOCKS, ERRORS, IO
  Only on the databases whose profile calls for them, so the healthy ones stay
  genuinely clean rather than quietly noisy.
==============================================================================*/
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
DECLARE @Srv1 sysname = N'demo-sql-prod-weu.database.windows.net';

INSERT core.BlockingChain
    (ServerName, DatabaseName, SnapshotUtc, BlockedSessionId, BlockingSessionId,
     HeadBlockerSessionId, ChainDepth, WaitType, WaitDurationMs, ResourceDescription,
     BlockedLogin, BlockedProgram, BlockedSql, BlockerLogin, BlockerHost,
     BlockerProgram, BlockerStatus, BlockerSql)
SELECT  @Srv1, 'OrdersDB', DATEADD(MINUTE, -7 * c.rn, @Now),
        CAST(120 + c.rn AS smallint),
        CAST(CASE WHEN c.rn = 0 THEN 98 ELSE 119 + c.rn END AS smallint),
        CAST(98 AS smallint), c.rn + 1,
        'LCK_M_X', 18000 + c.rn * 9000, 'KEY: 7:72057594043170816 (8194443284a0)',
        'svc_orders', 'OrderService.Api',
        'UPDATE dbo.Inventory SET OnHand = OnHand - @qty WHERE Sku = @sku',
        'svc_batch', 'APP-WEU-07', 'NightlyReconcile.exe', 'sleeping',
        'BEGIN TRAN; UPDATE dbo.Inventory SET OnHand = OnHand + @adj WHERE Sku = @sku'
FROM    (VALUES (0),(1),(2),(3),(4)) AS c(rn);

INSERT core.BlockingChain
    (ServerName, DatabaseName, SnapshotUtc, BlockedSessionId, BlockingSessionId,
     HeadBlockerSessionId, ChainDepth, WaitType, WaitDurationMs, ResourceDescription,
     BlockedLogin, BlockedProgram, BlockedSql, BlockerLogin, BlockerHost,
     BlockerProgram, BlockerStatus, BlockerSql)
SELECT  @Srv1, 'BillingDB', DATEADD(MINUTE, -21 * c.rn, @Now),
        CAST(210 + c.rn AS smallint), CAST(204 AS smallint), CAST(204 AS smallint), 1,
        'LCK_M_U', 7200 + c.rn * 2500, 'PAGE: 9:1:48213',
        'svc_billing', 'BillingRun', 'UPDATE dbo.Ledger SET Posted = 1 WHERE BatchId = @b',
        'svc_report', 'APP-WEU-02', 'PowerBI Gateway', 'running',
        'SELECT SUM(Amount) FROM dbo.Ledger WITH (HOLDLOCK) WHERE PostedUtc >= @from'
FROM    (VALUES (0),(1)) AS c(rn);

INSERT core.Deadlock
    (ServerName, DatabaseName, EventTimeUtc, VictimProcessId, ProcessCount,
     ObjectsInvolved, VictimSql, VictimLogin, VictimProgram, DeadlockGraph, EventSequence)
VALUES
 (N'demo-sql-prod-weu.database.windows.net','OrdersDB', DATEADD(MINUTE,-34,SYSUTCDATETIME()),
  'process1f8a4c', 2, 'dbo.Inventory, dbo.Orders',
  'UPDATE dbo.Inventory SET OnHand = OnHand - @qty WHERE Sku = @sku',
  'svc_orders','OrderService.Api',
  '<deadlock><victim-list><victimProcess id="process1f8a4c"/></victim-list></deadlock>', 1),
 (N'demo-sql-prod-weu.database.windows.net','OrdersDB', DATEADD(HOUR,-3,SYSUTCDATETIME()),
  'process2b11e9', 3, 'dbo.Orders, dbo.Customer, dbo.Address',
  'SELECT o.OrderId FROM dbo.Orders o JOIN dbo.Customer c ON c.CustomerId = o.CustomerId',
  'svc_orders','OrderService.Api',
  '<deadlock><victim-list><victimProcess id="process2b11e9"/></victim-list></deadlock>', 2);

INSERT core.ErrorEvent
    (ServerName, DatabaseName, EventTimeUtc, EventName, ErrorNumber, Severity,
     ErrorState, Message, SessionId, LoginName, ProgramName, HostName, SqlText, EventSequence)
SELECT  @Srv1,
        CASE WHEN e.rn % 2 = 0 THEN 'OrdersDB' ELSE 'BillingDB' END,
        DATEADD(MINUTE, -13 * e.rn - 4, @Now), 'error_reported',
        CASE e.rn % 3 WHEN 0 THEN 1205 WHEN 1 THEN 8134 ELSE 2627 END,
        CASE e.rn % 3 WHEN 0 THEN 13 WHEN 1 THEN 16 ELSE 14 END, 1,
        CASE e.rn % 3
          WHEN 0 THEN 'Transaction (Process ID 142) was deadlocked on lock resources with another process and has been chosen as the deadlock victim.'
          WHEN 1 THEN 'Divide by zero error encountered.'
          ELSE 'Violation of PRIMARY KEY constraint ''PK_Orders''. Cannot insert duplicate key in object ''dbo.Orders''.' END,
        CAST(140 + e.rn AS smallint), 'svc_orders', 'OrderService.Api', 'APP-WEU-03',
        'EXEC dbo.usp_PlaceOrder @CustomerId = @p1, @Sku = @p2', e.rn + 10
FROM    (VALUES (0),(1),(2),(3),(4),(5)) AS e(rn);

/*------------------------------------------------------------------------------
  IO - cumulative counters, two snapshots. Stall per read is what the latency
  view computes, so ReplicaDB is given a stall-to-read ratio that hurts.
------------------------------------------------------------------------------*/
INSERT core.IoFileStats
    (ServerName, DatabaseName, SnapshotUtc, FileId, FileName, TypeDesc, NumReads,
     BytesRead, IoStallReadMs, NumWrites, BytesWritten, IoStallWriteMs, SizeOnDiskMB)
SELECT  t.ServerName, t.DatabaseName, DATEADD(MINUTE, -30 * s.rn, @Now),
        f.FileId, f.FileName, f.TypeDesc,
        CAST(4200000 * (2 - s.rn) AS bigint),
        CAST(4200000 * 8192.0 * (2 - s.rn) AS bigint),
        CAST(CASE WHEN t.DatabaseName = 'ReplicaDB' THEN 196000000 ELSE 11000000 END
             * (2 - s.rn) / 2 AS bigint),
        CAST(1900000 * (2 - s.rn) AS bigint),
        CAST(1900000 * 8192.0 * (2 - s.rn) AS bigint),
        CAST(CASE WHEN t.DatabaseName = 'ReplicaDB' THEN 88000000 ELSE 4200000 END
             * (2 - s.rn) / 2 AS bigint),
        CASE f.TypeDesc WHEN 'LOG' THEN 24576.0 ELSE 61440.0 END
FROM    cfg.Target AS t
CROSS JOIN (VALUES (1,'data_0','ROWS'),(2,'log','LOG'),(3,'data_1','ROWS')) AS f(FileId,FileName,TypeDesc)
CROSS JOIN (VALUES (0),(1)) AS s(rn)
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName <> 'ArchiveDB';

PRINT 'blocking, deadlocks, errors and IO seeded';
GO


/*==============================================================================
  4. INDEX ESTATE, SECURITY, XE HEALTH
==============================================================================*/
DECLARE @Now datetime2(3) = SYSUTCDATETIME();
DECLARE @Today date = CAST(SYSUTCDATETIME() AS date);

DECLARE @ix TABLE (Tbl nvarchar(256), IxName nvarchar(256), IxType nvarchar(60),
                   Keys nvarchar(512), Rows_ bigint, SizeMB decimal(19,2),
                   Seeks bigint, Scans bigint, Updates bigint,
                   Frag decimal(9,2), Pages bigint);
INSERT @ix VALUES
 ('Orders','PK_Orders','CLUSTERED','OrderId',                4200000, 3100.00, 980000, 120, 410000,  4.20, 396800),
 ('Orders','IX_Orders_PlacedUtc','NONCLUSTERED','PlacedUtc', 4200000,  820.00, 410000,  40, 410000, 61.40, 104960),
 ('Orders','IX_Orders_Legacy','NONCLUSTERED','LegacyRef',    4200000,  640.00,      0,   0, 410000, 88.10,  81920),
 ('Inventory','PK_Inventory','CLUSTERED','Sku',               180000,  210.00, 740000,  10, 620000,  2.10,  26880),
 ('Inventory','IX_Inventory_Unused','NONCLUSTERED','Warehouse',180000,   96.00,     0,   0, 620000, 44.70,  12288),
 ('Ledger','PK_Ledger','CLUSTERED','LedgerId',               9800000, 7400.00, 310000, 820, 190000, 12.60, 947200),
 ('Ledger','IX_Ledger_PostedUtc','NONCLUSTERED','PostedUtc', 9800000, 1900.00, 290000,  60, 190000, 72.90, 243200),
 ('AuditTrail','PK_AuditTrail','CLUSTERED','AuditId',       21000000,14200.00,  41000,2400,  90000, 31.40,1817600);

INSERT core.IndexUsage
    (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, IndexName, IndexType,
     IsUnique, IsPrimaryKey, KeyColumns, RowCountEst, SizeMB, UserSeeks, UserScans,
     UserLookups, UserUpdates)
SELECT  t.ServerName, t.DatabaseName, DATEADD(DAY, -d.rn, @Today), 'dbo',
        i.Tbl, i.IxName, i.IxType,
        CASE WHEN i.IxType = 'CLUSTERED' THEN 1 ELSE 0 END,
        CASE WHEN i.IxName LIKE 'PK[_]%' THEN 1 ELSE 0 END,
        i.Keys, i.Rows_, i.SizeMB,
        i.Seeks / (d.rn + 1), i.Scans / (d.rn + 1), i.Seeks / 20 / (d.rn + 1), i.Updates / (d.rn + 1)
FROM    cfg.Target AS t CROSS JOIN @ix AS i CROSS JOIN (VALUES (0),(1),(2)) AS d(rn)
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName <> 'ArchiveDB';

/*------------------------------------------------------------------------------
  Fragmentation. Scaled PER DATABASE so the healthy ones are genuinely healthy:
  a demo where every database has the same problem teaches nothing, and a
  "healthy" control that still raises alerts is not a control.
------------------------------------------------------------------------------*/
INSERT core.IndexFragmentation
    (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, IndexName,
     AvgFragmentationPct, PageCount)
SELECT  t.ServerName, t.DatabaseName, @Today, 'dbo', i.Tbl, i.IxName,
        ROUND(i.Frag * CASE t.DatabaseName
                         WHEN 'OrdersDB'  THEN 1.00
                         WHEN 'BillingDB' THEN 0.85
                         WHEN 'ReplicaDB' THEN 0.60
                         ELSE 0.08                       -- CatalogDB, SandboxDB: clean
                       END, 2),
        i.Pages
FROM    cfg.Target AS t CROSS JOIN @ix AS i
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName <> 'ArchiveDB';

INSERT core.MissingIndex
    (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, EqualityColumns,
     InequalityColumns, IncludedColumns, UserSeeks, AvgUserImpact, ImpactScore, CreateStatement)
SELECT  t.ServerName, t.DatabaseName, @Today, 'dbo', m.Tbl, m.Eq, m.Ineq, m.Inc,
        m.Seeks, m.Impact, CAST(m.Seeks * m.Impact / 100.0 AS decimal(19,2)),
        'CREATE INDEX IX_' + m.Tbl + '_demo ON dbo.' + m.Tbl + ' (' + m.Eq + ')'
          + CASE WHEN m.Inc <> '' THEN ' INCLUDE (' + m.Inc + ')' ELSE '' END
FROM    cfg.Target AS t
CROSS JOIN (VALUES
    ('Orders','CustomerId, Status','PlacedUtc','TotalAmount, Currency', 412000, 94.20),
    ('Ledger','AccountId','PostedUtc','Amount',                         210000, 88.70),
    ('AuditTrail','EntityId','ChangedUtc','ChangedBy, OldValue',         96000, 71.30)
   ) AS m(Tbl, Eq, Ineq, Inc, Seeks, Impact)
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName IN ('OrdersDB','BillingDB');

INSERT core.TableSpace
    (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, RowCountEst,
     TotalMB, DataMB, IndexMB)
SELECT  t.ServerName, t.DatabaseName, @Today, 'dbo', x.Tbl, x.Rows_,
        x.Total, ROUND(x.Total * 0.74, 2), ROUND(x.Total * 0.26, 2)
FROM    cfg.Target AS t
CROSS JOIN (VALUES
    ('AuditTrail', 21000000, 14200.00), ('Ledger', 9800000, 9300.00),
    ('Orders', 4200000, 4560.00), ('EventLog', 3100000, 2180.00),
    ('Inventory', 180000, 306.00), ('Customer', 92000, 148.00)
   ) AS x(Tbl, Rows_, Total)
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName <> 'ArchiveDB';

/*------------------------------------------------------------------------------
  Security - two daily snapshots with a deliberate drift on BillingDB: a new
  principal appears today and holds CONTROL. That is exactly what
  core.vw_SecurityDrift exists to catch, and it needs yesterday to compare to.
------------------------------------------------------------------------------*/
INSERT core.SecurityPrincipal
    (ServerName, DatabaseName, SnapshotDate, PrincipalName, TypeDesc, AuthType,
     CreateDateUtc, ModifyDateUtc, RoleMemberships)
SELECT  t.ServerName, t.DatabaseName, DATEADD(DAY, -d.rn, @Today), p.Nm, p.Ty, p.Auth,
        DATEADD(DAY, -200, @Now), DATEADD(DAY, -12, @Now), p.Roles
FROM    cfg.Target AS t CROSS JOIN (VALUES (0),(1)) AS d(rn)
CROSS JOIN (VALUES
    ('dbo','SQL_USER','INSTANCE','db_owner'),
    ('svc_app','SQL_USER','DATABASE','db_datareader, db_datawriter'),
    ('svc_report','EXTERNAL_USER','EXTERNAL','db_datareader'),
    ('ops_readonly','EXTERNAL_USER','EXTERNAL','db_datareader')
   ) AS p(Nm, Ty, Auth, Roles)
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName <> 'ArchiveDB';

INSERT core.SecurityPrincipal
    (ServerName, DatabaseName, SnapshotDate, PrincipalName, TypeDesc, AuthType,
     CreateDateUtc, ModifyDateUtc, RoleMemberships)
SELECT  t.ServerName, t.DatabaseName, @Today, 'contractor_tmp', 'EXTERNAL_USER',
        'EXTERNAL', DATEADD(HOUR, -20, @Now), DATEADD(HOUR, -20, @Now), 'db_owner'
FROM    cfg.Target AS t
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName = 'BillingDB';

INSERT core.SecurityPermission
    (ServerName, DatabaseName, SnapshotDate, GranteeName, ClassDesc, ObjectName,
     PermissionName, StateDesc)
SELECT  t.ServerName, t.DatabaseName, DATEADD(DAY, -d.rn, @Today), g.Nm, g.Cls, g.Obj, g.Perm, g.St
FROM    cfg.Target AS t CROSS JOIN (VALUES (0),(1)) AS d(rn)
CROSS JOIN (VALUES
    ('svc_app','SCHEMA','dbo','SELECT','GRANT'),
    ('svc_app','SCHEMA','dbo','INSERT','GRANT'),
    ('svc_report','SCHEMA','dbo','SELECT','GRANT'),
    ('ops_readonly','DATABASE','(database)','VIEW DATABASE STATE','GRANT'),
    ('svc_report','OBJECT_OR_COLUMN','dbo.Customer','SELECT','DENY')
   ) AS g(Nm, Cls, Obj, Perm, St)
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName <> 'ArchiveDB';

INSERT core.SecurityPermission
    (ServerName, DatabaseName, SnapshotDate, GranteeName, ClassDesc, ObjectName,
     PermissionName, StateDesc)
SELECT  t.ServerName, t.DatabaseName, @Today, 'contractor_tmp', 'DATABASE', '(database)', 'CONTROL', 'GRANT'
FROM    cfg.Target AS t
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName = 'BillingDB';

/*------------------------------------------------------------------------------
  XE session health. OrdersDB has a STOPPED session - which is why its blocking
  coverage would otherwise be quietly incomplete, and a quiet gap in coverage is
  worse than a loud one.

  The Verdict strings are the collector's OWN vocabulary (see the XeHealth step
  in 22-jobs-standard.sql). The healthy value is 'Healthy'. Inventing a different
  word here would make the demo disagree with reality - and it is how the
  XE_UNHEALTHY rule was found comparing against 'OK', a value the collector never
  produces, so the alert fired on every healthy database.
------------------------------------------------------------------------------*/
INSERT core.XeSessionHealth
    (ServerName, DatabaseName, SnapshotUtc, SessionName, State,
     DroppedEventCount, DroppedBufferCount, Verdict)
SELECT  t.ServerName, t.DatabaseName, @Now, s.Nm,
        CASE WHEN t.DatabaseName = 'OrdersDB' AND s.Nm = 'ehd_blocking'
             THEN 'STOPPED' ELSE 'RUNNING' END,
        CASE WHEN t.DatabaseName = 'OrdersDB' AND s.Nm = 'ehd_errors' THEN 1842 ELSE 0 END, 0,
        CASE WHEN t.DatabaseName = 'OrdersDB' AND s.Nm = 'ehd_blocking'
                  THEN 'NOT RUNNING - no data being captured'
             WHEN t.DatabaseName = 'OrdersDB' AND s.Nm = 'ehd_errors'
                  THEN 'Dropping events - tighten predicates'
             ELSE 'Healthy' END
FROM    cfg.Target AS t
CROSS JOIN (VALUES ('ehd_errors'), ('ehd_blocking')) AS s(Nm)
WHERE   t.ServerName LIKE 'demo-%' AND t.DatabaseName <> 'ArchiveDB';

PRINT 'index estate, security and XE health seeded';
GO


/*==============================================================================
  5. FEED ARRIVAL
  What the dashboard reads for freshness. ArchiveDB's feeds stop 9 hours ago,
  which is what turns it into NOT REPORTING rather than simply quiet.
==============================================================================*/
DECLARE @Now datetime2(3) = SYSUTCDATETIME();

INSERT core.FeedArrival
    (ServerName, DatabaseName, FeedName, Tier, LastArrivalUtc, LastRowCount)
SELECT  t.ServerName, t.DatabaseName, f.Feed, f.Tier,
        CASE WHEN t.DatabaseName = 'ArchiveDB' THEN DATEADD(HOUR, -9, @Now)
             ELSE DATEADD(MINUTE, -1 * f.AgeMin, @Now) END,
        f.Rows_
FROM    cfg.Target AS t
CROSS JOIN (VALUES
    ('ResourceUsage','Frequent', 2, 240), ('ActiveRequest','Frequent', 3, 12),
    ('BlockingChain','Frequent', 3, 5),   ('SessionActivity','Frequent', 4, 28),
    ('WaitStats','Frequent', 4, 120),     ('QueryStats','Standard', 12, 25),
    ('QueryStore','Standard', 14, 25),    ('Space','Standard', 16, 1),
    ('Io','Standard', 17, 3),             ('XeErrors','Standard', 18, 6),
    ('XeBlocking','Standard', 19, 5),     ('XeHealth','Standard', 20, 2),
    ('IndexUsage','Daily', 240, 8),       ('MissingIndex','Daily', 242, 3),
    ('Fragmentation','Daily', 244, 8),    ('TableSpace','Daily', 246, 6),
    ('SecurityPrincipal','Daily', 248, 4),('SecurityPermission','Daily', 250, 5)
   ) AS f(Feed, Tier, AgeMin, Rows_)
WHERE   t.ServerName LIKE 'demo-%';

/*------------------------------------------------------------------------------
  Summary
------------------------------------------------------------------------------*/
SELECT  ServerName, DatabaseName,
        ResourceRows = (SELECT COUNT(*) FROM core.ResourceUsage r
                        WHERE r.ServerName = t.ServerName AND r.DatabaseName = t.DatabaseName),
        Feeds        = (SELECT COUNT(*) FROM core.FeedArrival a
                        WHERE a.ServerName = t.ServerName AND a.DatabaseName = t.DatabaseName),
        LastArrival  = (SELECT MAX(a.LastArrivalUtc) FROM core.FeedArrival a
                        WHERE a.ServerName = t.ServerName AND a.DatabaseName = t.DatabaseName)
FROM    cfg.Target AS t
WHERE   t.ServerName LIKE 'demo-%'
ORDER BY ServerName, DatabaseName;

PRINT '';
PRINT '=== demo estate seeded: 2 servers, 6 databases ===';
PRINT 'NEXT, so the alerts come from the real engine rather than being invented:';
PRINT '    EXEC core.usp_EvaluateAlerts;';
PRINT '';
PRINT 'To remove every trace of it:  tests\Remove-DemoEstate.sql';
GO
