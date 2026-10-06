/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 01-central/00-schemas-and-config.sql
  Run in : the CENTRAL repository database (one you own - NEVER a vendor database)

  ARCHITECTURAL PRINCIPLE
  -----------------------
  Nothing is ever created inside a monitored database. Every table, procedure,
  view and byte of state lives here. Elastic Jobs runs read-only SELECT
  statements against the targets and lands the results in [stg].

  Three schemas:
      cfg   configuration and the target registry
      stg   landing zone - Elastic Jobs writes here, auto-creating the tables
      core  modelled, de-duplicated, permanent

  Data flow:
      target DMV --(elastic job SELECT)--> stg.X --(normalize)--> core.X --> views

  IDEMPOTENT - safe to re-run.
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

IF SCHEMA_ID('cfg')  IS NULL EXEC (N'CREATE SCHEMA cfg  AUTHORIZATION dbo;');
IF SCHEMA_ID('stg')  IS NULL EXEC (N'CREATE SCHEMA stg  AUTHORIZATION dbo;');
IF SCHEMA_ID('core') IS NULL EXEC (N'CREATE SCHEMA core AUTHORIZATION dbo;');
GO

/*==============================================================================
  CONFIGURATION
==============================================================================*/
IF OBJECT_ID('cfg.Setting') IS NULL
CREATE TABLE cfg.Setting
(
    SettingKey   varchar(64)   NOT NULL CONSTRAINT PK_cfg_Setting PRIMARY KEY CLUSTERED,
    SettingValue nvarchar(256) NOT NULL,
    Description  nvarchar(512) NULL,
    ModifiedUtc  datetime2(3)  NOT NULL CONSTRAINT DF_cfg_Setting_Mod DEFAULT (SYSUTCDATETIME())
);
GO

/*------------------------------------------------------------------------------
  SETTINGS

  Every key here is READ by code. Every key read by code is defined here.
  That symmetry is enforced by tests\Test-SettingKeys.ps1 and it matters more
  than it looks:

    * a key that code reads but that is NOT defined falls back to the hard-coded
      default in the procedure. Tuning it with UPDATE cfg.Setting changes
      nothing, silently, because the UPDATE matches zero rows.

    * a key defined here but read by nothing is worse - it invites somebody to
      tune a number that can never have an effect.

  MERGE only inserts missing keys. Values you have already tuned are never
  overwritten by a redeploy.
------------------------------------------------------------------------------*/
MERGE cfg.Setting AS tgt
USING (VALUES
    ---------------------------------------------------------------- retention
    -- read by core.usp_Purge
    ('Retention.FrequentDays',      N'7',    N'ResourceUsage, ActiveRequest, BlockingChain, SessionActivity'),
    ('Retention.StandardDays',      N'35',   N'WaitStats, QueryStats, Space, Io, Errors, Deadlocks. Biggest storage lever.'),
    ('Retention.DailyDays',         N'400',  N'IndexUsage, MissingIndex, Fragmentation, TableSpace, Security'),
    ('Retention.AlertHistoryDays',  N'180',  N'core.AlertHistory'),
    ('Retention.StagingHours',      N'48',   N'How long landed staging rows are kept after normalization'),
    ('Retention.PurgeBatchRows',    N'50000',N'Rows deleted per DELETE batch. Floor of 1000 is enforced.'),

    -------------------------------------------------------------- staleness
    -- read by core.vw_TargetStatus and core.usp_EvaluateAlerts
    ('Stale.FrequentMinutes',       N'20',   N'Frequent job runs every 5 min; 20 = 4 missed runs'),
    ('Stale.StandardMinutes',       N'90',   N'Standard job runs every 30 min; 90 = 3 missed runs'),
    ('Stale.DailyMinutes',          N'1800', N'Daily job runs 02:30 UTC but stamps SnapshotDate (a DATE = midnight), so a fresh feed already reads ~26.5h old just before the next run. 30h covers that granularity; a genuinely missed run still reads ~50h and alerts.'),

    ------------------------------------------------------------------ staging
    -- read by core.usp_Normalize. THESE TWO ARE THE MOST IMPORTANT KEYS HERE.
    -- The Elastic Job Agent creates the stg.* tables itself and prepends its own
    -- bookkeeping columns. The names below are the current agent defaults; if
    -- your agent differs, normalization skips every feed until these match.
    -- Run tests\verify-staging-schema.sql to find out. Never remove these rows:
    -- without them the UPDATE in the fix instructions matches nothing.
    ('Staging.ServerColumn',        N'ServerName',   N'Identity column emitted by each collection query naming the source server'),
    ('Staging.DatabaseColumn',      N'DatabaseName', N'Identity column emitted by each collection query naming the source database'),

    ------------------------------------------------- alert thresholds: resource
    -- read by core.usp_EvaluateAlerts. Warn raises a Warning, Crit a Critical.
    -- Averaged over the trailing 15 minutes, so a single spike does not page.
    ('Alert.CpuWarnPct',            N'75',   N'avg_cpu_percent, 15-min average -> Warning'),
    ('Alert.CpuCritPct',            N'90',   N'avg_cpu_percent, 15-min average -> Critical'),
    ('Alert.DataIoWarnPct',         N'80',   N'avg_data_io_percent, 15-min average'),
    ('Alert.LogWriteWarnPct',       N'80',   N'avg_log_write_percent. 100% means the log rate governor is throttling.'),
    ('Alert.MemoryWarnPct',         N'90',   N'avg_memory_usage_percent. High alone is normal - correlate with RESOURCE_SEMAPHORE waits.'),
    ('Alert.WorkerWarnPct',         N'70',   N'max_worker_percent -> Warning'),
    ('Alert.WorkerCritPct',         N'90',   N'max_worker_percent -> Critical. At 100% logins fail with error 10928.'),
    ('Alert.SessionWarnPct',        N'70',   N'max_session_percent. Usually a connection pool not returning connections.'),

    ------------------------------------------------- alert thresholds: capacity
    ('Alert.SpaceWarnPct',          N'80',   N'Database size as % of MAXSIZE -> Warning'),
    ('Alert.SpaceCritPct',          N'90',   N'Database size as % of MAXSIZE -> Critical. At 100% inserts fail with 40544.'),
    ('Alert.LogSpaceWarnPct',       N'75',   N'Transaction log space used'),
    ('Alert.TempDbWarnPct',         N'70',   N'TempDB space used'),
    ('Alert.CapacityWarnDays',      N'30',   N'Projected days until MAXSIZE -> Warning'),
    ('Alert.CapacityCritDays',      N'7',    N'Projected days until MAXSIZE -> Critical'),
    ('Alert.LongTransactionMinutes',N'30',   N'Oldest open transaction. Blocks log truncation and holds locks.'),

    ---------------------------------------------- alert thresholds: concurrency
    ('Alert.BlockingSeconds',       N'30',   N'Longest block in the last 15 min -> Warning'),
    ('Alert.BlockingCritSeconds',   N'300',  N'Longest block in the last 15 min -> Critical'),
    ('Alert.DeadlocksPerDay',       N'3',    N'Deadlocks in the trailing 24 h before alerting'),

    -------------------------------------------------- alert thresholds: quality
    ('Alert.ErrorSeverity',         N'17',   N'Minimum error severity that counts toward ERROR_BURST'),
    ('Alert.ErrorCountPerHour',     N'5',    N'Errors at or above that severity in the trailing hour'),
    ('Alert.RegressionFactor',      N'2',    N'Current avg CPU vs 7-day baseline before QUERY_REGRESSION fires'),
    ('Alert.FragmentationPct',      N'30',   N'Fragmentation level counted by the FRAGMENTATION advisory'),
    ('Alert.JobFailurePct',         N'50',   N'% of collection job attempts that may fail in 24 h before JOB_FAILING')

    /* NOTE: there are deliberately NO Collect.* keys here.
       The collection queries live inside Elastic Job step definitions. A step's
       command text is fixed when the step is created and is not re-read from
       cfg.Setting at run time, so any Collect.* key would be permanently dead
       config. To change what is collected, edit the TOP (n) / threshold
       literals in 03-elasticjobs\21|22|23-jobs-*.sql and redeploy that file. */
) AS src (SettingKey, SettingValue, Description)
   ON tgt.SettingKey = src.SettingKey
WHEN NOT MATCHED BY TARGET THEN
    INSERT (SettingKey, SettingValue, Description)
    VALUES (src.SettingKey, src.SettingValue, src.Description);
GO

/*------------------------------------------------------------------------------
  Remove keys that older builds defined but nothing reads. Leaving them behind
  is a trap: somebody tunes Alert.CpuPct, nothing happens, and they lose an
  afternoon. Only the obsolete names are touched.
------------------------------------------------------------------------------*/
DELETE FROM cfg.Setting
WHERE SettingKey IN
(
    'Alert.CpuPct', 'Alert.DataIoPct', 'Alert.LogWritePct', 'Alert.MemoryPct',
    'Alert.WorkerPct', 'Alert.SessionPct', 'Alert.StoragePct', 'Alert.LogSpacePct',
    'Alert.TempDbPct', 'Alert.BlockedSessionCount', 'Alert.DeadlocksPerHour',
    'Alert.ErrorsPerHour', 'Alert.LongRunningQuerySec', 'Alert.SustainedMinutes',
    'Alert.MinIntervalMinutes', 'Alert.CapacityHorizonDays',
    'Collect.TopQueryCount', 'Collect.FragMinPageCount', 'Collect.LongRunningSeconds'
);
GO

CREATE OR ALTER FUNCTION cfg.fn_Int (@Key varchar(64), @Default int)
RETURNS int AS
BEGIN
    RETURN ISNULL(TRY_CAST((SELECT SettingValue FROM cfg.Setting WHERE SettingKey = @Key) AS int), @Default);
END;
GO

CREATE OR ALTER FUNCTION cfg.fn_Dec (@Key varchar(64), @Default decimal(9,2))
RETURNS decimal(9,2) AS
BEGIN
    RETURN ISNULL(TRY_CAST((SELECT SettingValue FROM cfg.Setting WHERE SettingKey = @Key) AS decimal(9,2)), @Default);
END;
GO


/*==============================================================================
  TARGET REGISTRY
  The estate, as you want it reported - not merely what Elastic Jobs happens to
  reach. Rows appear here two ways:
    * you register them explicitly (recommended - lets you record Environment,
      Owner, Criticality and, crucially, whether a target is vendor-owned)
    * core.usp_Normalize auto-registers anything that lands in staging
  A registered target that stops landing data is DETECTABLE. An unregistered one
  that disappears is not - which is why explicit registration matters.
==============================================================================*/
IF OBJECT_ID('cfg.Target') IS NULL
CREATE TABLE cfg.Target
(
    TargetId       int IDENTITY(1,1) NOT NULL CONSTRAINT PK_cfg_Target PRIMARY KEY CLUSTERED,
    ServerName     nvarchar(256) NOT NULL,
    DatabaseName   nvarchar(256) NOT NULL,
    Environment    varchar(32)   NOT NULL CONSTRAINT DF_cfg_Target_Env DEFAULT ('Default'),
    Owner          nvarchar(256) NULL,      -- team or DL responsible
    Criticality    varchar(16)   NULL,      -- Tier1 | Tier2 | Tier3
    IsVendorOwned  bit           NOT NULL CONSTRAINT DF_cfg_Target_Vendor  DEFAULT (0),
    IsEnabled      bit           NOT NULL CONSTRAINT DF_cfg_Target_Enabled DEFAULT (1),
    Notes          nvarchar(1000) NULL,
    FirstSeenUtc   datetime2(3)  NOT NULL CONSTRAINT DF_cfg_Target_First DEFAULT (SYSUTCDATETIME()),
    LastSeenUtc    datetime2(3)  NULL,
    CONSTRAINT UQ_cfg_Target UNIQUE (ServerName, DatabaseName)
);
GO

/*------------------------------------------------------------------------------
  Environment: default it, and make it stick.

  The CREATE TABLE above only runs on a NEW database, so an estate that already
  has cfg.Target would keep a nullable Environment with no default and never pick
  this up. These three steps bring an existing table to the same shape and are
  safe to re-run.

  Why it matters beyond tidiness: the dashboard groups and filters by
  Environment, and NULL is not a group - an unregistered or partially registered
  target would silently drop out of the Environment filter rather than show up
  as unclassified. 'Default' makes "nobody has classified this yet" a visible
  state instead of an absent one.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_cfg_Target_Env')
    ALTER TABLE cfg.Target ADD CONSTRAINT DF_cfg_Target_Env DEFAULT ('Default') FOR Environment;
GO

UPDATE cfg.Target SET Environment = 'Default' WHERE Environment IS NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('cfg.Target')
             AND name = 'Environment' AND is_nullable = 1)
    ALTER TABLE cfg.Target ALTER COLUMN Environment varchar(32) NOT NULL;
GO

CREATE OR ALTER PROCEDURE cfg.usp_RegisterTarget
    @ServerName    nvarchar(256),
    @DatabaseName  nvarchar(256),
    @Environment   varchar(32)   = NULL,
    @Owner         nvarchar(256) = NULL,
    @Criticality   varchar(16)   = NULL,
    @IsVendorOwned bit           = NULL,
    @Notes         nvarchar(1000)= NULL
AS
BEGIN
    SET NOCOUNT ON;

    /*--------------------------------------------------------------------------
      Store the SHORT server name, always.

      Every collection query stamps its rows with @@SERVERNAME, which on Azure
      SQL is 'ehd-server', not 'ehd-server.database.windows.net'. core.FeedArrival
      and the auto-registration in core.usp_RecordArrival therefore both key on
      the short name. An operator who registers a target the natural way - by
      pasting the fully qualified name they used to connect - would otherwise
      create a SECOND cfg.Target row that no feed can ever match, which then
      sits there raising NO_DATA forever while the database is collecting fine.

      Trimming here makes both spellings land on the same row.
    --------------------------------------------------------------------------*/
    SET @ServerName = LEFT(@ServerName, CHARINDEX('.', @ServerName + '.') - 1);

    MERGE cfg.Target AS t
    USING (SELECT @ServerName AS ServerName, @DatabaseName AS DatabaseName) AS s
       ON t.ServerName = s.ServerName AND t.DatabaseName = s.DatabaseName
    WHEN MATCHED THEN UPDATE SET
        Environment   = COALESCE(@Environment,   t.Environment),
        Owner         = COALESCE(@Owner,         t.Owner),
        Criticality   = COALESCE(@Criticality,   t.Criticality),
        IsVendorOwned = COALESCE(@IsVendorOwned, t.IsVendorOwned),
        Notes         = COALESCE(@Notes,         t.Notes)
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ServerName, DatabaseName, Environment, Owner, Criticality, IsVendorOwned, Notes)
        /* Environment is NOT NULL: an omitted @Environment must fall back to
           'Default' explicitly. The column DEFAULT does not fire here, because
           naming the column in the INSERT list and passing NULL is an explicit
           NULL, not an omission. */
        VALUES (@ServerName, @DatabaseName, ISNULL(@Environment, 'Default'),
                @Owner, @Criticality, ISNULL(@IsVendorOwned, 0), @Notes);
END;
GO


/*==============================================================================
  PROCESSING LOG
  One row per normalization / alert / purge pass. This is the central
  equivalent of the embedded edition's mon.CollectionRun, and it is what the
  staleness checks read.
==============================================================================*/
IF OBJECT_ID('core.ProcessRun') IS NULL
CREATE TABLE core.ProcessRun
(
    ProcessRunId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_core_ProcessRun PRIMARY KEY CLUSTERED,
    StepName      sysname       NOT NULL,
    StartedUtc    datetime2(3)  NOT NULL CONSTRAINT DF_core_ProcessRun_Started DEFAULT (SYSUTCDATETIME()),
    CompletedUtc  datetime2(3)  NULL,
    DurationMs    AS DATEDIFF_BIG(MILLISECOND, StartedUtc, CompletedUtc),
    Status        varchar(20)   NOT NULL CONSTRAINT DF_core_ProcessRun_Status DEFAULT ('Running'),
    RowsAffected  bigint        NULL,
    ErrorNumber   int           NULL,
    ErrorMessage  nvarchar(2048) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_core_ProcessRun_Started')
CREATE NONCLUSTERED INDEX IX_core_ProcessRun_Started
    ON core.ProcessRun (StartedUtc DESC) INCLUDE (StepName, Status);
GO

/*------------------------------------------------------------------------------
  DEPLOYMENT LOG - what is actually running in this database.

  Answers one question with certainty: "is the database running the script I
  have on disk, or an older copy of it?"

  That question used to be answered by inspecting a procedure's definition for
  a marker string. It is not reliable: the marker almost always appears in the
  COMMENT that describes it, so a stale deployment reports itself as current.
  A SHA-256 of the exact file bytes that were executed cannot be fooled that way.

  Written automatically by deploy\Invoke-EhdSql.py after a successful run.
  Deployments made any other way (SSMS, sqlcmd) do NOT appear here - which is
  itself useful information, because an absent or stale row means nobody can
  prove what is running.

  To compare disk against database:   .\tests\Test-Deployed.ps1
------------------------------------------------------------------------------*/
IF OBJECT_ID('cfg.DeployLog') IS NULL
CREATE TABLE cfg.DeployLog
(
    ScriptName  nvarchar(260) NOT NULL CONSTRAINT PK_cfg_DeployLog PRIMARY KEY CLUSTERED,
    FileSha256  char(64)      NOT NULL,
    FileBytes   int           NOT NULL,
    DeployedUtc datetime2(3)  NOT NULL CONSTRAINT DF_cfg_DeployLog_Utc DEFAULT (SYSUTCDATETIME()),
    DeployedBy  nvarchar(256) NULL
);
GO

/*------------------------------------------------------------------------------
  Per-target, per-feed arrival tracking. Answers "when did THIS database last
  send me THIS kind of data?" - the question that detects a silently dead
  target, which a global staleness check cannot.
------------------------------------------------------------------------------*/
IF OBJECT_ID('core.FeedArrival') IS NULL
CREATE TABLE core.FeedArrival
(
    ServerName     nvarchar(256) NOT NULL,
    DatabaseName   nvarchar(256) NOT NULL,
    FeedName       varchar(64)   NOT NULL,   -- ResourceUsage, Blocking, WaitStats, ...
    Tier           varchar(20)   NOT NULL,   -- Frequent | Standard | Daily
    LastArrivalUtc datetime2(3)  NOT NULL,
    LastRowCount   int           NULL,
    CONSTRAINT PK_core_FeedArrival PRIMARY KEY CLUSTERED (ServerName, DatabaseName, FeedName)
);
GO

PRINT '=== cfg / stg / core schemas, settings and target registry deployed ===';
SELECT SettingKey, SettingValue FROM cfg.Setting ORDER BY SettingKey;
GO