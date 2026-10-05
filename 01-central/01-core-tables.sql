/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 01-central/01-core-tables.sql
  Run in : the CENTRAL repository database

  The modelled, permanent tables. Every one is keyed by
  (ServerName, DatabaseName) because a single table now holds the whole estate -
  that is the entire point of the central design.

  Two categories:
    SNAPSHOT   value is meaningful as-is            (ResourceUsage, Space, ...)
    CUMULATIVE value only means something as a      (WaitStats, QueryStats, Io)
               difference between two collections

  Targets cannot hold state - no tables may be created there - so CUMULATIVE
  deltas are computed HERE with LAG() partitioned by target. That is the key
  structural difference from the embedded edition, where each database kept its
  own previous snapshot.
==============================================================================*/
/* Required SET options. sqlcmd.exe defaults QUOTED_IDENTIFIER to OFF, which makes
   CREATE INDEX fail on any filtered index and bakes the wrong options into views
   and procedures. SSMS and Invoke-Sqlcmd default it ON, so this only bites when
   deploying the documented way - with sqlcmd. Set it explicitly and the script
   behaves identically from every client. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*==============================================================================
  FREQUENT TIER  (Elastic Job every 5 minutes)
==============================================================================*/

/*------------------------------------------------------------------------------
  1. Resource usage - SNAPSHOT
     sys.dm_db_resource_stats exposes 15-second samples for the trailing hour.
     The job pulls the whole window every 5 minutes and we de-duplicate on
     (target, EndTimeUtc). Overlapping pulls are therefore harmless, and a
     missed run self-heals on the next pass with no data loss at all.
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.ResourceUsage') IS NULL
CREATE TABLE core.ResourceUsage
(
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    EndTimeUtc        datetime2(3)  NOT NULL,
    AvgCpuPct         decimal(9,4) NULL,
    AvgDataIoPct      decimal(9,4) NULL,
    AvgLogWritePct    decimal(9,4) NULL,
    AvgMemoryPct      decimal(9,4) NULL,
    MaxWorkerPct      decimal(9,4) NULL,
    MaxSessionPct     decimal(9,4) NULL,
    XtpStoragePct     decimal(9,4) NULL,
    AvgInstanceCpuPct decimal(9,4) NULL,
    DtuLimit          decimal(9,2) NULL,
    CpuLimit          decimal(9,2) NULL,
    LandedUtc         datetime2(3) NOT NULL CONSTRAINT DF_core_ResourceUsage_Landed DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_core_ResourceUsage PRIMARY KEY CLUSTERED (ServerName, DatabaseName, EndTimeUtc)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_ResourceUsage_Time')
CREATE NONCLUSTERED INDEX IX_core_ResourceUsage_Time
    ON core.ResourceUsage (EndTimeUtc DESC) INCLUDE (ServerName, DatabaseName, AvgCpuPct, MaxWorkerPct);
GO

/*------------------------------------------------------------------------------
  2. Active requests - SNAPSHOT
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.ActiveRequest') IS NULL
CREATE TABLE core.ActiveRequest
(
    ActiveRequestId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_ActiveRequest PRIMARY KEY CLUSTERED,
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    SnapshotUtc       datetime2(3)  NOT NULL,
    SessionId         smallint      NOT NULL,
    RequestId         int           NULL,
    Status            varchar(30)   NULL,
    Command           varchar(32)   NULL,
    WaitType          nvarchar(60)  NULL,
    WaitResource      nvarchar(256) NULL,
    WaitTimeMs        int           NULL,
    BlockingSessionId smallint      NULL,
    OpenTranCount     int           NULL,
    CpuTimeMs         int           NULL,
    TotalElapsedMs    int           NULL,
    LogicalReads      bigint        NULL,
    Writes            bigint        NULL,
    RowCountSoFar     bigint        NULL,
    GrantedMemoryKb   bigint        NULL,
    Dop               int           NULL,
    LoginName         nvarchar(256) NULL,
    HostName          nvarchar(256) NULL,
    ProgramName       nvarchar(256) NULL,
    QueryHash         varchar(20)   NULL,
    SqlText           nvarchar(max) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_ActiveRequest_Snap')
CREATE NONCLUSTERED INDEX IX_core_ActiveRequest_Snap
    ON core.ActiveRequest (SnapshotUtc DESC) INCLUDE (ServerName, DatabaseName, TotalElapsedMs);
GO

/*------------------------------------------------------------------------------
  3. Blocking chains - SNAPSHOT
     Polled at the job interval. Brief chains between polls are missed by this
     feed; the mon_ehd_blocking Extended Events session (02-targets) catches
     those continuously and is harvested into core.WaitEvent.
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.BlockingChain') IS NULL
CREATE TABLE core.BlockingChain
(
    BlockingChainId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_BlockingChain PRIMARY KEY CLUSTERED,
    ServerName           nvarchar(256) NOT NULL,
    DatabaseName         nvarchar(256) NOT NULL,
    SnapshotUtc          datetime2(3)  NOT NULL,
    BlockedSessionId     smallint      NOT NULL,
    BlockingSessionId    smallint      NOT NULL,
    HeadBlockerSessionId smallint      NULL,
    ChainDepth           int           NULL,
    WaitType             nvarchar(60)  NULL,
    WaitDurationMs       bigint        NULL,
    ResourceDescription  nvarchar(512) NULL,
    BlockedLogin         nvarchar(256) NULL,
    BlockedProgram       nvarchar(256) NULL,
    BlockedSql           nvarchar(max) NULL,
    BlockerLogin         nvarchar(256) NULL,
    BlockerHost          nvarchar(256) NULL,
    BlockerProgram       nvarchar(256) NULL,
    BlockerStatus        varchar(30)   NULL,
    BlockerSql           nvarchar(max) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_BlockingChain_Snap')
CREATE NONCLUSTERED INDEX IX_core_BlockingChain_Snap
    ON core.BlockingChain (SnapshotUtc DESC) INCLUDE (ServerName, DatabaseName, WaitDurationMs);
GO

/*------------------------------------------------------------------------------
  4. Session population - SNAPSHOT, pre-aggregated on the target
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.SessionActivity') IS NULL
CREATE TABLE core.SessionActivity
(
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    SnapshotUtc       datetime2(3)  NOT NULL,
    ProgramName       nvarchar(256) NOT NULL,
    LoginName         nvarchar(256) NOT NULL,
    HostName          nvarchar(256) NOT NULL,
    SessionCount      int NOT NULL,
    RunningCount      int NOT NULL,
    SleepingCount     int NOT NULL,
    BlockedCount      int NOT NULL,
    OpenTranCount     int NOT NULL,
    CONSTRAINT PK_core_SessionActivity PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, SnapshotUtc, ProgramName, LoginName, HostName)
);
GO

/*------------------------------------------------------------------------------
  5. Wait statistics - CUMULATIVE
     Raw counters land here; core.vw_WaitStatsDelta derives per-interval values
     with LAG() partitioned by (target, WaitType) and discards negative deltas,
     which indicate the counter was reset by a failover or scale operation.
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.WaitStats') IS NULL
CREATE TABLE core.WaitStats
(
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    SnapshotUtc       datetime2(3)  NOT NULL,
    WaitType          nvarchar(60)  NOT NULL,
    WaitingTasksCount bigint NOT NULL,
    WaitTimeMs        bigint NOT NULL,
    MaxWaitTimeMs     bigint NOT NULL,
    SignalWaitTimeMs  bigint NOT NULL,
    CONSTRAINT PK_core_WaitStats PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, WaitType, SnapshotUtc)
);
GO


/*==============================================================================
  STANDARD TIER  (Elastic Job every 30 minutes)
==============================================================================*/

/*------------------------------------------------------------------------------
  6. Query statistics - CUMULATIVE per (QueryHash, PlanHash)
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.QueryStats') IS NULL
CREATE TABLE core.QueryStats
(
    ServerName         nvarchar(256) NOT NULL,
    DatabaseName       nvarchar(256) NOT NULL,
    SnapshotUtc        datetime2(3)  NOT NULL,
    QueryHash          varchar(20)   NOT NULL,
    QueryPlanHash      varchar(20)   NOT NULL,
    ExecutionCount     bigint NOT NULL,
    TotalWorkerTimeUs  bigint NOT NULL,
    TotalElapsedTimeUs bigint NOT NULL,
    TotalLogicalReads  bigint NOT NULL,
    TotalLogicalWrites bigint NOT NULL,
    TotalPhysicalReads bigint NOT NULL,
    TotalRows          bigint NOT NULL,
    ObjectName         nvarchar(512) NULL,
    SampleSqlText      nvarchar(max) NULL,
    CONSTRAINT PK_core_QueryStats PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, QueryHash, QueryPlanHash, SnapshotUtc)
);
GO

/*------------------------------------------------------------------------------
  7. Query Store extract - SNAPSHOT of a closed interval
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.QueryStoreTopQuery') IS NULL
CREATE TABLE core.QueryStoreTopQuery
(
    QueryStoreTopQueryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_QsTop PRIMARY KEY CLUSTERED,
    ServerName       nvarchar(256) NOT NULL,
    DatabaseName     nvarchar(256) NOT NULL,
    SnapshotUtc      datetime2(3)  NOT NULL,
    IntervalEndUtc   datetimeoffset(7) NULL,
    QueryId          bigint NOT NULL,
    PlanId           bigint NOT NULL,
    ObjectName       nvarchar(512) NULL,
    ExecutionCount   bigint NULL,
    AvgDurationMs    decimal(19,3) NULL,
    AvgCpuMs         decimal(19,3) NULL,
    TotalCpuMs       decimal(19,3) NULL,
    AvgLogicalReads  decimal(19,3) NULL,
    AvgTempDbSpaceKb decimal(19,3) NULL,
    AvgMemoryGrantKb decimal(19,3) NULL,
    TopWaitCategory  nvarchar(60)  NULL,
    QueryText        nvarchar(max) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_core_QsTop_Dedupe')
CREATE UNIQUE NONCLUSTERED INDEX UX_core_QsTop_Dedupe
    ON core.QueryStoreTopQuery (ServerName, DatabaseName, QueryId, PlanId, IntervalEndUtc)
    WHERE IntervalEndUtc IS NOT NULL;
GO

/*------------------------------------------------------------------------------
  8. Space - SNAPSHOT
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.DatabaseSpace') IS NULL
CREATE TABLE core.DatabaseSpace
(
    ServerName       nvarchar(256) NOT NULL,
    DatabaseName     nvarchar(256) NOT NULL,
    SnapshotUtc      datetime2(3)  NOT NULL,
    AllocatedMB      decimal(19,2) NULL,
    UsedMB           decimal(19,2) NULL,
    MaxSizeMB        decimal(19,2) NULL,
    PctOfMaxSize     decimal(9,4)  NULL,
    DataUsedMB       decimal(19,2) NULL,
    IndexUsedMB      decimal(19,2) NULL,
    ServiceObjective nvarchar(64)  NULL,
    Edition          nvarchar(64)  NULL,
    CONSTRAINT PK_core_DatabaseSpace PRIMARY KEY CLUSTERED (ServerName, DatabaseName, SnapshotUtc)
);
GO

IF OBJECT_ID('core.LogSpace') IS NULL
CREATE TABLE core.LogSpace
(
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    SnapshotUtc       datetime2(3)  NOT NULL,
    TotalLogSizeMB    decimal(19,2) NULL,
    UsedLogSpaceMB    decimal(19,2) NULL,
    UsedLogSpacePct   decimal(9,4)  NULL,
    LogReuseWaitDesc  nvarchar(60)  NULL,
    OldestTranBeginUtc datetime2(3) NULL,
    OldestTranSessionId smallint    NULL,
    CONSTRAINT PK_core_LogSpace PRIMARY KEY CLUSTERED (ServerName, DatabaseName, SnapshotUtc)
);
GO

IF OBJECT_ID('core.TempDbUsage') IS NULL
CREATE TABLE core.TempDbUsage
(
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    SnapshotUtc       datetime2(3)  NOT NULL,
    TotalMB           decimal(19,2) NULL,
    AllocatedMB       decimal(19,2) NULL,
    PctUsed           decimal(9,4)  NULL,
    UserObjectsMB     decimal(19,2) NULL,
    InternalObjectsMB decimal(19,2) NULL,
    VersionStoreMB    decimal(19,2) NULL,
    CONSTRAINT PK_core_TempDbUsage PRIMARY KEY CLUSTERED (ServerName, DatabaseName, SnapshotUtc)
);
GO

/*------------------------------------------------------------------------------
  9. IO - CUMULATIVE
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.IoFileStats') IS NULL
CREATE TABLE core.IoFileStats
(
    ServerName     nvarchar(256) NOT NULL,
    DatabaseName   nvarchar(256) NOT NULL,
    SnapshotUtc    datetime2(3)  NOT NULL,
    FileId         int           NOT NULL,
    FileName       nvarchar(256) NULL,
    TypeDesc       nvarchar(60)  NULL,
    NumReads       bigint NULL,
    BytesRead      bigint NULL,
    IoStallReadMs  bigint NULL,
    NumWrites      bigint NULL,
    BytesWritten   bigint NULL,
    IoStallWriteMs bigint NULL,
    SizeOnDiskMB   decimal(19,2) NULL,
    CONSTRAINT PK_core_IoFileStats PRIMARY KEY CLUSTERED (ServerName, DatabaseName, FileId, SnapshotUtc)
);
GO

/*------------------------------------------------------------------------------
  10. Errors and deadlocks - harvested from the target Extended Events ring
      buffers. EventSequence + EventTimeUtc give a natural de-duplication key,
      which matters because the ring buffer is re-read on every harvest and
      returns the same events until they age out.
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.ErrorEvent') IS NULL
CREATE TABLE core.ErrorEvent
(
    ErrorEventId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_ErrorEvent PRIMARY KEY CLUSTERED,
    ServerName    nvarchar(256) NOT NULL,
    DatabaseName  nvarchar(256) NOT NULL,
    EventTimeUtc  datetime2(3)  NOT NULL,
    EventName     sysname       NULL,
    ErrorNumber   int           NULL,
    Severity      int           NULL,
    ErrorState    int           NULL,
    Message       nvarchar(max) NULL,
    SessionId     int           NULL,
    LoginName     nvarchar(256) NULL,
    ProgramName   nvarchar(256) NULL,
    HostName      nvarchar(256) NULL,
    SqlText       nvarchar(max) NULL,
    EventSequence bigint        NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_ErrorEvent_Time')
CREATE NONCLUSTERED INDEX IX_core_ErrorEvent_Time
    ON core.ErrorEvent (EventTimeUtc DESC) INCLUDE (ServerName, DatabaseName, ErrorNumber, Severity);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_core_ErrorEvent_Dedupe')
CREATE UNIQUE NONCLUSTERED INDEX UX_core_ErrorEvent_Dedupe
    ON core.ErrorEvent (ServerName, DatabaseName, EventTimeUtc, EventSequence)
    WHERE EventSequence IS NOT NULL;
GO

IF OBJECT_ID('core.Deadlock') IS NULL
CREATE TABLE core.Deadlock
(
    DeadlockId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_Deadlock PRIMARY KEY CLUSTERED,
    ServerName      nvarchar(256) NOT NULL,
    DatabaseName    nvarchar(256) NOT NULL,
    EventTimeUtc    datetime2(3)  NOT NULL,
    VictimProcessId nvarchar(50)  NULL,
    ProcessCount    int           NULL,
    ObjectsInvolved nvarchar(max) NULL,
    VictimSql       nvarchar(max) NULL,
    VictimLogin     nvarchar(256) NULL,
    VictimProgram   nvarchar(256) NULL,
    DeadlockGraph   xml           NULL,
    EventSequence   bigint        NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_Deadlock_Time')
CREATE NONCLUSTERED INDEX IX_core_Deadlock_Time
    ON core.Deadlock (EventTimeUtc DESC) INCLUDE (ServerName, DatabaseName);
GO

/*------------------------------------------------------------------------------
  11. Long waits harvested from the blocking XE session - catches the chains
      that fall between polls.
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.WaitEvent') IS NULL
CREATE TABLE core.WaitEvent
(
    WaitEventId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_WaitEvent PRIMARY KEY CLUSTERED,
    ServerName    nvarchar(256) NOT NULL,
    DatabaseName  nvarchar(256) NOT NULL,
    EventTimeUtc  datetime2(3)  NOT NULL,
    EventName     sysname       NULL,
    WaitType      nvarchar(128) NULL,
    DurationMs    bigint        NULL,
    SessionId     int           NULL,
    LoginName     nvarchar(256) NULL,
    ProgramName   nvarchar(256) NULL,
    SqlText       nvarchar(max) NULL,
    EventSequence bigint        NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_core_WaitEvent_Dedupe')
CREATE UNIQUE NONCLUSTERED INDEX UX_core_WaitEvent_Dedupe
    ON core.WaitEvent (ServerName, DatabaseName, EventTimeUtc, EventSequence)
    WHERE EventSequence IS NOT NULL;
GO

/*------------------------------------------------------------------------------
  12. Service objective change log - only written when something actually
      changes, so it doubles as an audit trail of autoscale and manual resizes.
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.ServiceObjectiveChange') IS NULL
CREATE TABLE core.ServiceObjectiveChange
(
    ChangeId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_SloChange PRIMARY KEY CLUSTERED,
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    DetectedUtc       datetime2(3)  NOT NULL,
    Edition           nvarchar(64)  NULL,
    ServiceObjective  nvarchar(64)  NULL,
    MaxSizeMB         decimal(19,2) NULL,
    PreviousObjective nvarchar(64)  NULL
);
GO


/*==============================================================================
  DAILY TIER
==============================================================================*/
IF OBJECT_ID('core.IndexUsage') IS NULL
CREATE TABLE core.IndexUsage
(
    ServerName      nvarchar(256) NOT NULL,
    DatabaseName    nvarchar(256) NOT NULL,
    SnapshotDate    date          NOT NULL,
    SchemaName      nvarchar(256) NOT NULL,
    TableName       nvarchar(256) NOT NULL,
    IndexName       nvarchar(256) NOT NULL,
    IndexType       nvarchar(60)  NULL,
    IsUnique        bit           NULL,
    IsPrimaryKey    bit           NULL,
    KeyColumns      nvarchar(max) NULL,
    IncludedColumns nvarchar(max) NULL,
    RowCountEst     bigint        NULL,
    SizeMB          decimal(19,2) NULL,
    UserSeeks       bigint        NULL,
    UserScans       bigint        NULL,
    UserLookups     bigint        NULL,
    UserUpdates     bigint        NULL,
    CONSTRAINT PK_core_IndexUsage PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, IndexName)
);
GO

IF OBJECT_ID('core.MissingIndex') IS NULL
CREATE TABLE core.MissingIndex
(
    MissingIndexId    bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_MissingIndex PRIMARY KEY CLUSTERED,
    ServerName        nvarchar(256) NOT NULL,
    DatabaseName      nvarchar(256) NOT NULL,
    SnapshotDate      date          NOT NULL,
    SchemaName        nvarchar(256) NULL,
    TableName         nvarchar(256) NULL,
    EqualityColumns   nvarchar(max) NULL,
    InequalityColumns nvarchar(max) NULL,
    IncludedColumns   nvarchar(max) NULL,
    UserSeeks         bigint        NULL,
    AvgUserImpact     float         NULL,
    ImpactScore       float         NULL,
    CreateStatement   nvarchar(max) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_MissingIndex_Snap')
CREATE NONCLUSTERED INDEX IX_core_MissingIndex_Snap
    ON core.MissingIndex (SnapshotDate DESC, ImpactScore DESC) INCLUDE (ServerName, DatabaseName);
GO

IF OBJECT_ID('core.IndexFragmentation') IS NULL
CREATE TABLE core.IndexFragmentation
(
    ServerName          nvarchar(256) NOT NULL,
    DatabaseName        nvarchar(256) NOT NULL,
    SnapshotDate        date          NOT NULL,
    SchemaName          nvarchar(256) NOT NULL,
    TableName           nvarchar(256) NOT NULL,
    IndexName           nvarchar(256) NOT NULL,
    AvgFragmentationPct decimal(9,4)  NULL,
    PageCount           bigint        NULL,
    RecommendedAction   AS (CASE WHEN AvgFragmentationPct >= 30 THEN 'REBUILD'
                                 WHEN AvgFragmentationPct >= 10 THEN 'REORGANIZE'
                                 ELSE 'NONE' END),
    CONSTRAINT PK_core_IndexFrag PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName, IndexName)
);
GO

IF OBJECT_ID('core.TableSpace') IS NULL
CREATE TABLE core.TableSpace
(
    ServerName   nvarchar(256) NOT NULL,
    DatabaseName nvarchar(256) NOT NULL,
    SnapshotDate date          NOT NULL,
    SchemaName   nvarchar(256) NOT NULL,
    TableName    nvarchar(256) NOT NULL,
    RowCountEst  bigint        NULL,
    TotalMB      decimal(19,2) NULL,
    DataMB       decimal(19,2) NULL,
    IndexMB      decimal(19,2) NULL,
    CONSTRAINT PK_core_TableSpace PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, SnapshotDate, SchemaName, TableName)
);
GO

IF OBJECT_ID('core.SecurityPrincipal') IS NULL
CREATE TABLE core.SecurityPrincipal
(
    ServerName      nvarchar(256) NOT NULL,
    DatabaseName    nvarchar(256) NOT NULL,
    SnapshotDate    date          NOT NULL,
    PrincipalName   nvarchar(256) NOT NULL,
    TypeDesc        nvarchar(60)  NULL,
    AuthType        nvarchar(60)  NULL,
    CreateDateUtc   datetime2(3)  NULL,
    ModifyDateUtc   datetime2(3)  NULL,
    RoleMemberships nvarchar(max) NULL,
    CONSTRAINT PK_core_SecPrincipal PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, SnapshotDate, PrincipalName)
);
GO

IF OBJECT_ID('core.SecurityPermission') IS NULL
CREATE TABLE core.SecurityPermission
(
    ServerName     nvarchar(256) NOT NULL,
    DatabaseName   nvarchar(256) NOT NULL,
    SnapshotDate   date          NOT NULL,
    GranteeName    nvarchar(256) NOT NULL,
    ClassDesc      nvarchar(60)  NOT NULL,
    ObjectName     nvarchar(512) NOT NULL,
    PermissionName nvarchar(128) NOT NULL,
    StateDesc      nvarchar(60)  NOT NULL,
    CONSTRAINT PK_core_SecPermission PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, SnapshotDate, GranteeName, ClassDesc, ObjectName, PermissionName, StateDesc)
);
GO

IF OBJECT_ID('core.XeSessionHealth') IS NULL
CREATE TABLE core.XeSessionHealth
(
    ServerName         nvarchar(256) NOT NULL,
    DatabaseName       nvarchar(256) NOT NULL,
    SnapshotUtc        datetime2(3)  NOT NULL,
    SessionName        nvarchar(256) NOT NULL,
    State              varchar(10)   NULL,
    DroppedEventCount  bigint        NULL,
    DroppedBufferCount bigint        NULL,
    Verdict            nvarchar(200) NULL,
    CONSTRAINT PK_core_XeHealth PRIMARY KEY CLUSTERED
        (ServerName, DatabaseName, SessionName, SnapshotUtc)
);
GO


/*==============================================================================
  ALERTING - one table for the whole estate
==============================================================================*/
IF OBJECT_ID('core.AlertHistory') IS NULL
CREATE TABLE core.AlertHistory
(
    AlertId        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_AlertHistory PRIMARY KEY CLUSTERED,
    ServerName     nvarchar(256) NOT NULL,
    DatabaseName   nvarchar(256) NOT NULL,
    RaisedUtc      datetime2(3)  NOT NULL CONSTRAINT DF_core_Alert_Raised DEFAULT (SYSUTCDATETIME()),
    AlertCode      varchar(64)   NOT NULL,
    Severity       varchar(16)   NOT NULL,
    Category       varchar(32)   NOT NULL,
    Metric         varchar(64)   NULL,
    ObservedValue  decimal(19,4) NULL,
    ThresholdValue decimal(19,4) NULL,
    Message        nvarchar(1000) NOT NULL,
    Detail         nvarchar(max) NULL,
    IsNotified     bit           NOT NULL CONSTRAINT DF_core_Alert_Notified DEFAULT (0),
    ResolvedUtc    datetime2(3)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_Alert_Open')
CREATE NONCLUSTERED INDEX IX_core_Alert_Open
    ON core.AlertHistory (ServerName, DatabaseName, AlertCode, RaisedUtc DESC)
    WHERE ResolvedUtc IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_Alert_Raised')
CREATE NONCLUSTERED INDEX IX_core_Alert_Raised
    ON core.AlertHistory (RaisedUtc DESC) INCLUDE (Severity, AlertCode, ResolvedUtc);
GO

PRINT '=== core tables deployed ===';
SELECT TableName = s.name + '.' + t.name, Rows = SUM(p.rows)
FROM   sys.tables t
JOIN   sys.schemas s ON s.schema_id = t.schema_id
JOIN   sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE  s.name IN ('core','cfg')
GROUP BY s.name, t.name
ORDER BY TableName;
GO
