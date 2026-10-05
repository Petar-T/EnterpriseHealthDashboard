/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 02-targets/11-target-xe-sessions.sql
  Run by : Elastic Job "EHD_Setup" against every target (one-time, idempotent)

  Deploys two database-scoped Extended Events sessions into each target.

  WHY THESE ARE ACCEPTABLE UNDER A NO-DEPLOYMENT RULE
  ---------------------------------------------------
  An event session is database-scoped *metadata*, not a schema object. It
  creates no table, no procedure, no view, and holds no application data. It can
  be removed with a single DROP that leaves nothing behind.

  WHY THEY EARN THEIR KEEP
  ------------------------
  Polling from outside can only see the instant it looks. These sessions capture
  continuously and the collection job simply harvests the ring buffer every 30
  minutes. That is how a 30-minute job still catches a deadlock that lasted
  200 ms at 03:14.

  RING BUFFER ONLY - NO BLOB TARGET
  ---------------------------------
  Deliberately no event_file target: that would require a DATABASE SCOPED
  CREDENTIAL in the vendor database and would write to storage from inside it.
  The ring buffer is memory-only, needs no credential, and is read with a plain
  SELECT. Durability comes from harvesting into the central store instead.

  SIZING: 4 MB ring buffers, ALLOW_SINGLE_EVENT_LOSS, low-volume predicates.
  Steady-state overhead is negligible because both sessions fire only on
  failure or on genuinely long waits.
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
  SESSION 1  ehd_errors - errors, attentions, deadlock graphs
==============================================================================*/
DECLARE @sql nvarchar(max);

IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'ehd_errors')
   AND NOT EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = N'ehd_errors')
BEGIN
    -- defined but not running: just start it
    EXEC (N'ALTER EVENT SESSION [ehd_errors] ON DATABASE STATE = START;');
    PRINT 'ehd_errors: restarted';
END
ELSE IF NOT EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'ehd_errors')
BEGIN
    /* Events are validated against sys.dm_xe_objects before being added so the
       script degrades gracefully instead of failing outright when a service
       tier does not surface one of them. */
    DECLARE @ev TABLE (Ordinal int IDENTITY(1,1) PRIMARY KEY, EventName sysname, Clause nvarchar(max));

    INSERT INTO @ev (EventName, Clause) VALUES
    (N'sqlserver.error_reported', N'
    ADD EVENT sqlserver.error_reported(
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.client_app_name,
                sqlserver.client_hostname, sqlserver.server_principal_name,
                sqlserver.session_id, sqlserver.query_hash, package0.event_sequence)
        WHERE (severity >= (11)
           AND error_number <> 3621 AND error_number <> 5701
           AND error_number <> 5703 AND error_number <> 2528))'),
    (N'sqlserver.attention', N'
    ADD EVENT sqlserver.attention(
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.client_app_name,
                sqlserver.session_id, sqlserver.query_hash, package0.event_sequence))'),
    (N'sqlserver.database_xml_deadlock_report', N'
    ADD EVENT sqlserver.database_xml_deadlock_report(
        ACTION (sqlserver.database_name, sqlserver.client_app_name,
                sqlserver.server_principal_name, sqlserver.session_id,
                package0.event_sequence))');

    DECLARE @MetaOk bit = 1;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_objects WHERE object_type = 'event') SET @MetaOk = 0;
    END TRY BEGIN CATCH SET @MetaOk = 0; END CATCH;

    DECLARE @events nvarchar(max) = N'';
    SELECT @events = @events + CASE WHEN @events = N'' THEN N'' ELSE N',' END + e.Clause
    FROM   @ev AS e
    WHERE  @MetaOk = 0
       OR  EXISTS (SELECT 1 FROM sys.dm_xe_objects o
                   JOIN sys.dm_xe_packages p ON p.guid = o.package_guid
                   WHERE o.object_type = 'event' AND p.name + '.' + o.name = e.EventName)
    ORDER BY e.Ordinal;

    IF @events <> N''
    BEGIN
        SET @sql = N'CREATE EVENT SESSION [ehd_errors] ON DATABASE' + @events + N'
        ADD TARGET package0.ring_buffer(SET max_memory = (4096), max_events_limit = (2000))
        WITH (MAX_MEMORY = 4096 KB,
              EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
              MAX_DISPATCH_LATENCY = 20 SECONDS,
              MAX_EVENT_SIZE = 0 KB,
              MEMORY_PARTITION_MODE = NONE,
              TRACK_CAUSALITY = ON,
              STARTUP_STATE = ON);';
        EXEC sys.sp_executesql @sql;
        EXEC (N'ALTER EVENT SESSION [ehd_errors] ON DATABASE STATE = START;');
        PRINT 'ehd_errors: created and started';
    END
    ELSE PRINT 'ehd_errors: no supported events on this tier - skipped';
END
ELSE PRINT 'ehd_errors: already running';
GO

/*==============================================================================
  SESSION 2  ehd_blocking - long lock waits and lock escalation

  This is what makes a 30-minute poll acceptable. sqlos.wait_info fires the
  moment a lock wait exceeds the threshold, so blocking that starts and ends
  between two polls is still captured.
==============================================================================*/
DECLARE @sql2 nvarchar(max);
DECLARE @WaitThresholdMs int = 5000;

IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'ehd_blocking')
   AND NOT EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions WHERE name = N'ehd_blocking')
BEGIN
    EXEC (N'ALTER EVENT SESSION [ehd_blocking] ON DATABASE STATE = START;');
    PRINT 'ehd_blocking: restarted';
END
ELSE IF NOT EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'ehd_blocking')
BEGIN
    DECLARE @ev2 TABLE (Ordinal int IDENTITY(1,1) PRIMARY KEY, EventName sysname, Clause nvarchar(max));
    DECLARE @w nvarchar(20) = CAST(@WaitThresholdMs AS nvarchar(20));

    INSERT INTO @ev2 (EventName, Clause) VALUES
    (N'sqlos.wait_info', N'
    ADD EVENT sqlos.wait_info(
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.session_id,
                sqlserver.client_app_name, sqlserver.server_principal_name,
                sqlserver.query_hash, package0.event_sequence)
        WHERE (duration > (' + @w + N') AND sqlserver.is_system = 0))'),
    (N'sqlserver.lock_escalation', N'
    ADD EVENT sqlserver.lock_escalation(
        ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.session_id,
                sqlserver.client_app_name, package0.event_sequence))');

    DECLARE @MetaOk2 bit = 1;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_objects WHERE object_type = 'event') SET @MetaOk2 = 0;
    END TRY BEGIN CATCH SET @MetaOk2 = 0; END CATCH;

    DECLARE @events2 nvarchar(max) = N'';
    SELECT @events2 = @events2 + CASE WHEN @events2 = N'' THEN N'' ELSE N',' END + e.Clause
    FROM   @ev2 AS e
    WHERE  @MetaOk2 = 0
       OR  EXISTS (SELECT 1 FROM sys.dm_xe_objects o
                   JOIN sys.dm_xe_packages p ON p.guid = o.package_guid
                   WHERE o.object_type = 'event' AND p.name + '.' + o.name = e.EventName)
    ORDER BY e.Ordinal;

    IF @events2 <> N''
    BEGIN
        SET @sql2 = N'CREATE EVENT SESSION [ehd_blocking] ON DATABASE' + @events2 + N'
        ADD TARGET package0.ring_buffer(SET max_memory = (4096), max_events_limit = (2000))
        WITH (MAX_MEMORY = 4096 KB,
              EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
              MAX_DISPATCH_LATENCY = 20 SECONDS,
              MAX_EVENT_SIZE = 0 KB,
              MEMORY_PARTITION_MODE = NONE,
              TRACK_CAUSALITY = ON,
              STARTUP_STATE = ON);';
        EXEC sys.sp_executesql @sql2;
        EXEC (N'ALTER EVENT SESSION [ehd_blocking] ON DATABASE STATE = START;');
        PRINT 'ehd_blocking: created and started';
    END
    ELSE PRINT 'ehd_blocking: no supported events on this tier - skipped';
END
ELSE PRINT 'ehd_blocking: already running';
GO

/*==============================================================================
  VERIFY
==============================================================================*/
SELECT  SessionName = s.name,
        State   = CASE WHEN r.name IS NULL THEN 'STOPPED' ELSE 'RUNNING' END,
        r.dropped_event_count,
        r.dropped_buffer_count
FROM    sys.database_event_sessions s
LEFT   JOIN sys.dm_xe_database_sessions r ON r.name = s.name
WHERE   s.name LIKE 'ehd[_]%';
GO

/*==============================================================================
  COMPLETE REMOVAL - leaves no trace in the target database
  Run this and the vendor database is exactly as it was.
==============================================================================*/
/*
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'ehd_errors')
    DROP EVENT SESSION [ehd_errors] ON DATABASE;
IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'ehd_blocking')
    DROP EVENT SESSION [ehd_blocking] ON DATABASE;
*/
GO
