/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 02-targets/12-target-querystore.sql
  Run by : Elastic Job "EHD_Setup" against every target (idempotent)

  Enables and right-sizes Query Store. This is an ALTER DATABASE SET - a
  database SETTING, not an object. Nothing is created, nothing to remove.

  WHY IT MATTERS HERE
  -------------------
  Query Store is the single highest-value feed available under a
  no-deployment rule. It gives per-query runtime and wait statistics with plan
  history, which is most of what the embedded edition's collectors provided -
  and the target does all the aggregation for you.

  IT IS ALSO PROBABLY ALREADY ON
  ------------------------------
  Query Store is ON by default for new Azure SQL databases, so in many cases
  this script changes nothing at all. Section 0 tells you before you touch
  anything - run it first and, if the vendor is sensitive, show them the output.

  SAFETY
  ------
  The script never downgrades an existing configuration. It only raises
  MAX_STORAGE_SIZE_MB, never lowers it, and it will not switch an explicitly
  chosen QUERY_CAPTURE_MODE. If Query Store is READ_ONLY because it hit its
  size limit, it reports that rather than silently resizing.
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

/*==============================================================================
  0. REPORT CURRENT STATE - always safe, changes nothing
==============================================================================*/
SELECT  DatabaseName        = DB_NAME(),
        DesiredState        = desired_state_desc,
        ActualState         = actual_state_desc,
        ReadOnlyReason      = readonly_reason,
        CurrentSizeMB       = current_storage_size_mb,
        MaxSizeMB           = max_storage_size_mb,
        IntervalMinutes     = interval_length_minutes,
        CaptureMode         = query_capture_mode_desc,
        WaitStatsCapture    = wait_stats_capture_mode_desc,
        StaleQueryDays      = (SELECT TRY_CAST(JSON_VALUE(stale_query_threshold_days, '$') AS int)),
        CleanupMode         = size_based_cleanup_mode_desc
FROM    sys.database_query_store_options;
GO

/*==============================================================================
  1. ENABLE AND RIGHT-SIZE - only what is actually needed
==============================================================================*/
DECLARE @DesiredMaxMB    int = 1024;   -- raise only, never lower
DECLARE @DesiredInterval int = 15;     -- 15-minute aggregation intervals
DECLARE @DesiredStaleDays int = 30;

DECLARE @state    nvarchar(60);
DECLARE @maxMB    bigint;
DECLARE @interval bigint;
DECLARE @capture  nvarchar(60);
DECLARE @waitMode nvarchar(60);
DECLARE @roReason int;
DECLARE @sql      nvarchar(max);

SELECT TOP (1)
       @state    = actual_state_desc,
       @maxMB    = max_storage_size_mb,
       @interval = interval_length_minutes,
       @capture  = query_capture_mode_desc,
       @waitMode = wait_stats_capture_mode_desc,
       @roReason = readonly_reason
FROM   sys.database_query_store_options;

/*---------------------------------------------------------------- 1a. turn on */
IF @state = 'OFF'
BEGIN
    PRINT 'Query Store is OFF - enabling.';
    ALTER DATABASE CURRENT SET QUERY_STORE = ON;
    SET @state = 'READ_WRITE';
END
ELSE IF @state = 'READ_ONLY'
BEGIN
    /* readonly_reason is a bit mask; 65536 = size limit reached. */
    PRINT 'WARNING: Query Store is READ_ONLY (readonly_reason = '
          + CAST(ISNULL(@roReason, 0) AS varchar(20)) + ').';
    IF ISNULL(@roReason, 0) & 65536 = 65536
        PRINT '  Cause: storage limit reached. Raising MAX_STORAGE_SIZE_MB below will restore READ_WRITE.';
    ELSE
        PRINT '  Cause is not the size limit - investigate before changing anything.';
END
ELSE PRINT 'Query Store is already ' + ISNULL(@state, '(unknown)') + '.';

/*---------------------------------------------------------------- 1b. size */
IF ISNULL(@maxMB, 0) < @DesiredMaxMB
BEGIN
    PRINT 'Raising MAX_STORAGE_SIZE_MB from ' + CAST(ISNULL(@maxMB,0) AS varchar(20))
          + ' to ' + CAST(@DesiredMaxMB AS varchar(20)) + '.';
    SET @sql = N'ALTER DATABASE CURRENT SET QUERY_STORE (MAX_STORAGE_SIZE_MB = '
             + CAST(@DesiredMaxMB AS nvarchar(20)) + N');';
    EXEC sys.sp_executesql @sql;
END
ELSE PRINT 'MAX_STORAGE_SIZE_MB already >= desired - left alone.';

/*---------------------------------------------------------------- 1c. interval */
IF ISNULL(@interval, 0) <> @DesiredInterval
BEGIN
    PRINT 'Setting INTERVAL_LENGTH_MINUTES to ' + CAST(@DesiredInterval AS varchar(10)) + '.';
    SET @sql = N'ALTER DATABASE CURRENT SET QUERY_STORE (INTERVAL_LENGTH_MINUTES = '
             + CAST(@DesiredInterval AS nvarchar(10)) + N');';
    EXEC sys.sp_executesql @sql;
END

/*---------------------------------------------------------------- 1d. hygiene */
ALTER DATABASE CURRENT SET QUERY_STORE (SIZE_BASED_CLEANUP_MODE = AUTO);

SET @sql = N'ALTER DATABASE CURRENT SET QUERY_STORE
             (CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = '
         + CAST(@DesiredStaleDays AS nvarchar(10)) + N'));';
EXEC sys.sp_executesql @sql;

/*---------------------------------------------------------------- 1e. waits */
IF ISNULL(@waitMode, 'OFF') = 'OFF'
BEGIN
    PRINT 'Enabling WAIT_STATS_CAPTURE_MODE - needed for per-query wait analysis.';
    ALTER DATABASE CURRENT SET QUERY_STORE (WAIT_STATS_CAPTURE_MODE = ON);
END

/*---------------------------------------------------------------- 1f. capture */
/* AUTO excludes trivial one-off queries and is the right default. An explicit
   ALL or CUSTOM is a deliberate choice by whoever owns the database - respect it. */
IF ISNULL(@capture, '') = ''
    ALTER DATABASE CURRENT SET QUERY_STORE (QUERY_CAPTURE_MODE = AUTO);
ELSE
    PRINT 'QUERY_CAPTURE_MODE is ' + @capture + ' - left as configured.';
GO

/*==============================================================================
  2. CONFIRM
==============================================================================*/
SELECT  DatabaseName   = DB_NAME(),
        ActualState    = actual_state_desc,
        CurrentSizeMB  = current_storage_size_mb,
        MaxSizeMB      = max_storage_size_mb,
        IntervalMinutes= interval_length_minutes,
        CaptureMode    = query_capture_mode_desc,
        WaitStats      = wait_stats_capture_mode_desc,
        Verdict        = CASE
            WHEN actual_state_desc = 'READ_WRITE' THEN 'Ready'
            WHEN actual_state_desc = 'READ_ONLY'  THEN 'READ_ONLY - feed will stagnate'
            ELSE 'OFF - Query Store feeds unavailable' END
FROM    sys.database_query_store_options;
GO

/*==============================================================================
  REVERT - returns the setting to OFF, leaving nothing behind
  Only do this if Query Store was OFF before you started; check section 0 output.
==============================================================================*/
/*
ALTER DATABASE CURRENT SET QUERY_STORE = OFF;
*/
GO
