/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 02-targets/10-target-permissions.sql

  WHAT THIS CREATES IN A VENDOR DATABASE:  nothing, if Option A works.

  Option A (PREFERRED - zero footprint in the target database)
  ------------------------------------------------------------
  Azure SQL Database supports server-level roles that live in [master] and grant
  their permission across every database on the logical server. Membership of
  ##MS_ServerStateReader## confers VIEW DATABASE STATE everywhere WITHOUT a user
  existing in any user database.

  That is the whole answer to "we may not deploy anything in the vendor
  database": the login and its permission live in master, which you own.

  Option B (fallback - one contained user per target database)
  ------------------------------------------------------------
  If your server does not expose the server-level roles, you must create a
  database principal in each target and grant it VIEW DATABASE STATE. That is a
  principal, not a schema object - usually acceptable - but it IS a change to
  the vendor database, so get it agreed first.

  VERIFY BEFORE PROMISING ANYTHING TO A VENDOR
  --------------------------------------------
  Run section 0 below against your server and read the result. Do not assume
  Option A is available; confirm it.
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
  0. CAPABILITY CHECK - run this in [master] FIRST
==============================================================================*/
/*
SELECT  RoleName  = dp.name,
        RoleType  = dp.type_desc,
        Available = 'yes'
FROM    sys.database_principals AS dp
WHERE   dp.name IN ('##MS_ServerStateReader##',
                    '##MS_DefinitionReader##',
                    '##MS_ServerStateManager##');

-- No rows  -> Option A is unavailable on this server; use Option B.
-- Rows     -> Option A is available. Proceed with section 1.
*/
GO


/*==============================================================================
  OPTION A - server-level, zero footprint in any user database
  Run in [master] on EACH monitored logical server.

  THIS IS ALSO REQUIRED, regardless of option, when a target group contains a
  SERVER rather than individual databases: the agent logs in to that server's
  master to enumerate databases, so the identity must exist there.
==============================================================================*/
/*
-- A1. The elastic job agent's USER-ASSIGNED MANAGED IDENTITY. Preferred:
--     no password to rotate, and mandatory on Entra-only servers where
--     CREATE LOGIN ... WITH PASSWORD is rejected outright.
--     The name is the UMI resource name, exactly as it appears in Azure.
CREATE LOGIN [ehd-agent-umi] FROM EXTERNAL PROVIDER;

-- A2. CONNECT. This one is easy to miss and nothing else works without it.
--     ##MS_ServerStateReader## and ##MS_DefinitionReader## grant the right to
--     READ once you are inside a database; neither grants the right to GET
--     inside one. With no user in the target database, the login needs
--     CONNECT ANY DATABASE, which is what this role confers. Omit it and every
--     target fails at login with "Cannot open database ... requested by the
--     login", which reads like a firewall or name problem and is neither.
ALTER SERVER ROLE ##MS_DatabaseConnector## ADD MEMBER [ehd-agent-umi];

-- A3. The DMVs - this is what the collection queries actually read.
ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [ehd-agent-umi];

-- A4. Metadata visibility. Required by more than just Query Store: without it
--     sys.tables, sys.indexes and OBJECT_NAME() return NOTHING rather than
--     erroring, so the Daily feeds silently come back empty and look like a
--     database with no tables in it.
ALTER SERVER ROLE ##MS_DefinitionReader## ADD MEMBER [ehd-agent-umi];

-- A5. SQL login alternative, ONLY when Entra authentication is not an option.
--     Illegal on servers with azureADOnlyAuthentication = true.
--     Do not mix: one agent uses EITHER managed identity OR credentials,
--     never both across different targets.
-- CREATE LOGIN [ehd_collector] WITH PASSWORD = '<strong-password>';
-- ALTER SERVER ROLE ##MS_DatabaseConnector##  ADD MEMBER [ehd_collector];
-- ALTER SERVER ROLE ##MS_ServerStateReader##  ADD MEMBER [ehd_collector];
-- ALTER SERVER ROLE ##MS_DefinitionReader##   ADD MEMBER [ehd_collector];

-- A6. Verify membership. Expect THREE rows for the collector identity.
SELECT  MemberName = m.name, RoleName = r.name
FROM    sys.server_role_members AS rm
JOIN    sys.server_principals   AS r ON r.principal_id = rm.role_principal_id
JOIN    sys.server_principals   AS m ON m.principal_id = rm.member_principal_id
WHERE   r.name LIKE '##MS[_]%'
ORDER BY m.name, r.name;
*/
GO


/*==============================================================================
  OPTION B - contained user per target database
  Run in EACH TARGET DATABASE. This DOES create a principal in the vendor
  database - agree it first.

  Note what is NOT granted: no CREATE, no ALTER on their objects, no data
  access. VIEW DATABASE STATE exposes DMVs only, never table contents.
==============================================================================*/
/*
-- B1. Managed identity, when the UMI has NO login in master (database-scoped
--     targets only - this form will not work for whole-server target members).
CREATE USER [ehd-agent-umi] FROM EXTERNAL PROVIDER;
GRANT VIEW DATABASE STATE            TO [ehd-agent-umi];   -- DMVs
GRANT VIEW DEFINITION                TO [ehd-agent-umi];   -- object names for index/table feeds
GRANT ALTER ANY DATABASE EVENT SESSION TO [ehd-agent-umi]; -- only if you deploy the XE sessions

-- B2. When a login already exists in master (Option A), map it instead:
CREATE USER [ehd-agent-umi] FROM LOGIN [ehd-agent-umi];

-- B3. SQL-auth equivalent, where Entra is not available:
CREATE USER [ehd_collector] FOR LOGIN [ehd_collector];
GRANT VIEW DATABASE STATE TO [ehd_collector];
GRANT VIEW DEFINITION     TO [ehd_collector];

-- Deliberately NOT granted:
--   db_datareader   - the collector never reads application data
--   CONTROL / ALTER - no schema changes of any kind
*/
GO


/*==============================================================================
  1. WHAT EACH FEED ACTUALLY REQUIRES
     Use this to negotiate the minimum viable permission set with a vendor.
==============================================================================*/
SELECT * FROM (VALUES
 ('ResourceUsage',   'sys.dm_db_resource_stats',            'VIEW DATABASE STATE', 'no'),
 ('ActiveRequests',  'sys.dm_exec_requests / _sessions',    'VIEW DATABASE STATE', 'no'),
 ('Blocking',        'sys.dm_exec_requests',                'VIEW DATABASE STATE', 'no'),
 ('SessionActivity', 'sys.dm_exec_sessions',                'VIEW DATABASE STATE', 'no'),
 ('WaitStats',       'sys.dm_db_wait_stats',                'VIEW DATABASE STATE', 'no'),
 ('QueryStats',      'sys.dm_exec_query_stats',             'VIEW DATABASE STATE', 'no'),
 ('Space',           'sys.database_files, dm_db_partition_stats', 'VIEW DATABASE STATE', 'no'),
 ('Io',              'sys.dm_io_virtual_file_stats',        'VIEW DATABASE STATE', 'no'),
 ('QueryStore',      'sys.query_store_*',                   'VIEW DATABASE STATE + VIEW DEFINITION', 'Query Store ON'),
 ('IndexUsage',      'sys.dm_db_index_usage_stats, sys.indexes', 'VIEW DATABASE STATE + VIEW DEFINITION', 'no'),
 ('MissingIndex',    'sys.dm_db_missing_index_*',           'VIEW DATABASE STATE', 'no'),
 ('Fragmentation',   'sys.dm_db_index_physical_stats',      'VIEW DATABASE STATE + VIEW DEFINITION', 'no'),
 ('TableSpace',      'sys.tables, dm_db_partition_stats',   'VIEW DEFINITION', 'no'),
 ('SecurityDrift',   'sys.database_principals / _permissions','VIEW DEFINITION', 'no'),
 ('ErrorsDeadlocks', 'XE ring buffer via dm_xe_database_session_targets', 'VIEW DATABASE STATE', 'XE session deployed'),
 ('XeHealth',        'sys.dm_xe_database_sessions',         'VIEW DATABASE STATE', 'XE session deployed')
) AS v(Feed, ReadsFrom, MinimumPermission, TargetSideChange)
ORDER BY Feed;
GO

PRINT '';
PRINT 'Summary of footprint in a monitored database:';
PRINT '  Option A : none whatsoever (login + role live in master)';
PRINT '  Option B : one database user, read-only on DMVs, no data access';
PRINT '  XE       : 2 event sessions (database-scoped metadata, no schema objects)';
PRINT '  QS       : one ALTER DATABASE SET QUERY_STORE - a setting, not an object';
GO
