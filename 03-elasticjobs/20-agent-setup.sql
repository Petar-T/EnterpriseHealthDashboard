/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 03-elasticjobs/20-agent-setup.sql
  Run in : THE database - the one that is both the Elastic Job Agent's job
           database and the central repository. Never a target.

  ------------------------------------------------------------------------------
  ONE DATABASE, TWO ROLES
  ------------------------------------------------------------------------------
  This edition deliberately puts the job agent and the repository in the SAME
  Azure SQL Database. The agent owns the [jobs] schema; we own [cfg], [stg] and
  [core]. They coexist without interfering.

  What that buys:

      * jobs.job_executions sits next to core.FeedArrival, so "this feed is
        stale - did the job fail, and why?" is ONE query instead of two
        connections to two databases. core.vw_JobHealth does exactly that, and
        it is why the dashboard can show a real failure count and the actual
        error text.
      * One connection string, one credential story, one backup, one bill.
      * A restore restores everything consistently - job definitions and the
        history they produced cannot drift apart.

  What it costs, stated plainly:

      * The identity that writes collected data lives in the same database as
        the job control plane. Left unchecked, that identity could modify
        jobs.jobsteps - i.e. change the SQL that runs against your targets.
        Section 1 below closes that with an explicit DENY. Do not skip it.

  ------------------------------------------------------------------------------
  HOW ELASTIC JOBS PULLS DATA - the mechanism this whole edition rests on
  ------------------------------------------------------------------------------
  sp_add_jobstep accepts @output_* parameters. When supplied, the agent:

      1. connects to each target in the target group
      2. runs @command there (for us: a read-only SELECT against DMVs)
      3. takes the result set
      4. writes it into a table in a database YOU nominate - here, this one

  So the query executes inside the vendor database - which is unavoidable,
  because DMVs are database-scoped - but the RESULT is stored here. Nothing is
  created in the target. That is precisely the property a no-deployment rule
  demands.

  ------------------------------------------------------------------------------
  THE OUTPUT TABLE IS CREATED BY THE AGENT, NOT BY YOU
  ------------------------------------------------------------------------------
  If the output table does not exist, Elastic Jobs creates it, deriving the
  columns from the result set and adding EXACTLY ONE column of its own:

      internal_execution_id   uniqueidentifier
      (plus a nonclustered index IX_<TableName>_Internal_Execution_ID on it)

  THAT IS ALL IT ADDS. There is no last_modify_time, no target_server_name and
  no target_database_name. Those last two are columns of the jobs.job_executions
  CATALOG VIEW, which is a completely different object - conflating the two is a
  common and expensive mistake, and it caused three separate defects here before
  being pinned down.

  Microsoft, verbatim:
      "Columns with the correct name and data types for the result set.
       Additional column for internal_execution_id with the data type of
       uniqueidentifier."
      - learn.microsoft.com/azure/azure-sql/database/elastic-jobs-tsql-create-manage

  So EVERY collection query emits its own identity and its own timestamp, which
  is the documented pattern in Microsoft's own sample:

      ServerName   = CAST(@@SERVERNAME AS nvarchar(256)),
      DatabaseName = DB_NAME(),
      SnapshotUtc  = <the feed's timestamp>,

  Those columns are what make one shared table per feed work across the estate,
  and what lets core.usp_RecordArrival and core.usp_PurgeStaging tell rows apart
  and age them out.

  DO NOT PRE-CREATE stg.* TABLES. A column mismatch makes the insert fail.
  Let the agent create them on first run, then confirm the real shape with
  tests/verify-staging-schema.sql before trusting normalization.

  ------------------------------------------------------------------------------
  PREREQUISITES (PowerShell, once)
  ------------------------------------------------------------------------------
      # one database, sized for the repository - the agent's own footprint is
      # negligible next to the collected history
      New-AzSqlDatabase -ResourceGroupName $rg -ServerName $srv `
          -DatabaseName 'EnterpriseHealth' -RequestedServiceObjectiveName 'S2'

      $db = Get-AzSqlDatabase -ResourceGroupName $rg -ServerName $srv `
                              -DatabaseName 'EnterpriseHealth'
      New-AzSqlElasticJobAgent -Name 'ehd-agent' -DatabaseObject $db

  Sharing one database between the agent and the repository is SUPPORTED, not a
  workaround. A job database is an ordinary Azure SQL Database: the agent adds
  its own [jobs] and [jobs_internal] schemas and leaves everything else alone.
  Microsoft's "point the agent at a clean database" line is guidance to avoid
  surprises, not a product restriction.

  The only genuine constraint is 1:1 in ONE direction - a job database hosts
  exactly one agent, and an existing agent cannot be repointed elsewhere.
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
  1. THE MANAGED IDENTITY AND THE PRIVILEGE BOUNDARY

  This edition authenticates with the job agent's USER-ASSIGNED MANAGED IDENTITY
  (UMI), not database-scoped credentials. Microsoft is explicit:

      "When using Microsoft Entra authentication, omit the @credential_name
       parameter, which should only be provided when using database-scoped
       credentials."

  So there are NO credentials to create, and @credential_name,
  @output_credential_name and @refresh_credential_name are absent everywhere.

  YOU CANNOT MIX THE TWO. Per Microsoft: "for a single elastic job agent, you
  can't configure one target server to use database-scoped credentials and
  another to use Microsoft Entra ID authentication." It is UMI for everything,
  or credentials for everything.

  WHERE THE UMI NEEDS A USER
  --------------------------
    * every TARGET database        - read-only, to run the collection queries
    * the OUTPUT database (here)   - to CREATE the stg.* tables and INSERT
    * NOT for the agent's own job database connection - that uses internal
      certificate-based authentication and needs nothing from you

  THE BOUNDARY
  ------------
  The UMI must NOT be db_owner here. In a single-database design db_owner also
  grants rights over [jobs], which would let the identity that writes monitoring
  data rewrite the commands that run against production. Grant precisely what it
  needs, then DENY the rest.

  READ versus WRITE on [jobs] are two separate decisions, and both are required:
    * READ  - via the agent's own jobs_reader role, so core.vw_JobHealth and
              usp_EvaluateAlerts can explain why a feed went stale.
    * WRITE - DENIED outright, so the collector can never touch the control
              plane that schedules commands against production.
  Omitting the read half does not fail loudly: normalization keeps working and
  only alert evaluation dies, which looks like an alerting bug rather than a
  permissions one.
==============================================================================*/
DECLARE @umi sysname = N'ehd-agent-umi';   -- the agent's user-assigned managed identity

IF DATABASE_PRINCIPAL_ID(@umi) IS NULL
BEGIN
    PRINT 'MISSING: the managed identity user in this (output) database.';
    PRINT '  Run the block below, substituting your UMI name.';
END
ELSE
    PRINT 'Managed identity user present: ' + @umi;
GO

/*
-- ---------------------------------------------------------------------------
-- Run ONCE in THIS database (the job + output database).
-- No secrets, no master key, no credentials - that is the point of the UMI.
-- ---------------------------------------------------------------------------
CREATE USER [ehd-agent-umi] FROM EXTERNAL PROVIDER;

-- what the agent legitimately needs to land results here
GRANT CREATE TABLE TO [ehd-agent-umi];               -- agent creates stg.* on first run
GRANT ALTER   ON SCHEMA::stg  TO [ehd-agent-umi];    -- ...inside stg, nowhere else
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::stg  TO [ehd-agent-umi];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::core TO [ehd-agent-umi];
GRANT SELECT  ON SCHEMA::cfg  TO [ehd-agent-umi];
GRANT EXECUTE ON SCHEMA::core TO [ehd-agent-umi];    -- usp_Normalize / EvaluateAlerts / Purge
GRANT VIEW DEFINITION TO [ehd-agent-umi];            -- fn_StagingReady inspects sys.columns

-- READ job history. core.vw_JobHealth -> core.vw_JobExecution -> jobs.job_executions,
-- and usp_EvaluateAlerts reads that view to explain WHY a feed went stale.
-- Ownership chaining does not carry across schemas owned by different principals,
-- so without this you get:
--     "The SELECT permission was denied on the object 'job_executions'"
-- and every alert evaluation fails while normalization keeps working - a
-- confusing split failure.
--
-- jobs_reader is created by the agent for precisely this purpose and grants
-- SELECT on [jobs] and nothing on [jobs_internal]. The DENY block below still
-- wins for every form of write, so this reads without widening anything.
ALTER ROLE jobs_reader ADD MEMBER [ehd-agent-umi];

-- ONLY IF this database is also a COLLECTION TARGET (it is the first one, by
-- design - a safe estate of one). The grants above are for landing results;
-- these are what the read-only collection queries need to read DMVs here.
GRANT VIEW DATABASE STATE TO [ehd-agent-umi];
-- GRANT ALTER ANY DATABASE EVENT SESSION TO [ehd-agent-umi];  -- only if you run EHD_Setup_Targets here

-- THE BOUNDARY. Every form of write against the job control plane is refused,
-- while the SELECT granted by jobs_reader above survives.
--
-- NOTE THE ABSENCE OF **CONTROL**, AND DO NOT ADD IT BACK.
-- CONTROL implies EVERY permission on the securable, so DENY ... CONTROL also
-- denies SELECT - and DENY beats GRANT and beats role membership. Including it
-- silently revokes the jobs_reader read access this system needs, producing:
--     "The SELECT permission was denied on the object 'job_executions'"
-- while every other part of the pipeline keeps working. Deny the specific write
-- permissions instead; that is both narrower and actually correct.
DENY INSERT, UPDATE, DELETE, ALTER, EXECUTE ON SCHEMA::jobs TO [ehd-agent-umi];

-- jobs_internal is different: the identity needs NOTHING from it, so the
-- catch-all DENY is appropriate here.
DENY INSERT, UPDATE, DELETE, ALTER, CONTROL ON SCHEMA::jobs_internal TO [ehd-agent-umi];
*/
GO

/*------------------------------------------------------------------------------
  Verify the boundary actually took - BOTH halves of it.

  Asserting "a DENY exists" is not enough: a DENY that is too broad passes that
  check while silently breaking the system. DENY ... CONTROL on [jobs] denies
  SELECT as well, which kills core.vw_JobHealth and every job-failure alert, and
  nothing else misbehaves - so it reads as an alerting bug for as long as you
  care to look. This block fails that case loudly.

  Expect: jobs           -> WritesDenied=1, ReadBlocked=0
          jobs_internal  -> WritesDenied=1  (read is irrelevant there)
------------------------------------------------------------------------------*/
DECLARE @umiName sysname = N'ehd-agent-umi';

IF DATABASE_PRINCIPAL_ID(@umiName) IS NOT NULL
BEGIN
    SELECT  SchemaName   = s.name,
            WritesDenied = MAX(CASE WHEN p.state_desc = 'DENY'
                                     AND p.permission_name IN ('INSERT','UPDATE','DELETE','ALTER','EXECUTE','CONTROL')
                                    THEN 1 ELSE 0 END),
            /* CONTROL and SELECT denials both block reads - CONTROL implies SELECT */
            ReadBlocked  = MAX(CASE WHEN p.state_desc = 'DENY'
                                     AND p.permission_name IN ('SELECT','CONTROL')
                                    THEN 1 ELSE 0 END),
            Verdict      = CASE
                WHEN s.name = 'jobs'
                 AND MAX(CASE WHEN p.state_desc = 'DENY'
                               AND p.permission_name IN ('SELECT','CONTROL') THEN 1 ELSE 0 END) = 1
                    THEN 'BROKEN - reads are denied on [jobs]. DENY CONTROL implies DENY SELECT. '
                       + 'Run: REVOKE CONTROL ON SCHEMA::jobs FROM [' + @umiName + '];'
                WHEN MAX(CASE WHEN p.state_desc = 'DENY'
                               AND p.permission_name IN ('INSERT','UPDATE','DELETE','ALTER','EXECUTE','CONTROL')
                              THEN 1 ELSE 0 END) = 0
                    THEN 'REVIEW - no write DENY found on this schema'
                ELSE 'ok - writes denied, reads intact' END
    FROM    sys.database_permissions AS p
    JOIN    sys.schemas AS s ON s.schema_id = p.major_id
    WHERE   p.class = 3
      AND   p.grantee_principal_id = DATABASE_PRINCIPAL_ID(@umiName)
      AND   s.name IN ('jobs', 'jobs_internal')
    GROUP BY s.name;

    /* The read half has to be positively confirmed, not merely "not denied". */
    SELECT  Check_ = 'read access to [jobs]',
            JobsReaderMember = ISNULL(IS_ROLEMEMBER('jobs_reader', @umiName), 0),
            ExplicitSelect   = CASE WHEN EXISTS (
                                        SELECT 1 FROM sys.database_permissions p
                                        JOIN sys.schemas s ON s.schema_id = p.major_id
                                        WHERE p.class = 3 AND s.name = 'jobs'
                                          AND p.state_desc = 'GRANT' AND p.permission_name = 'SELECT'
                                          AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(@umiName))
                                    THEN 1 ELSE 0 END,
            Verdict = CASE WHEN ISNULL(IS_ROLEMEMBER('jobs_reader', @umiName), 0) = 1
                             OR EXISTS (SELECT 1 FROM sys.database_permissions p
                                        JOIN sys.schemas s ON s.schema_id = p.major_id
                                        WHERE p.class = 3 AND s.name = 'jobs'
                                          AND p.state_desc = 'GRANT' AND p.permission_name = 'SELECT'
                                          AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(@umiName))
                           THEN 'ok - job history is readable'
                           ELSE 'MISSING - usp_EvaluateAlerts will fail on jobs.job_executions. '
                              + 'Run: ALTER ROLE jobs_reader ADD MEMBER [' + @umiName + '];' END;
END
ELSE
    PRINT 'The managed identity user does not exist yet - create it with the block above.';
GO


/*==============================================================================
  2. TARGET GROUPS

  A group whose member is a SERVER expands automatically to every database on
  it - new databases are picked up with no job change. That is usually what you
  want for an estate, with explicit exclusions for anything that must not be
  touched.

  Refresh credential: when a group member is a SERVER, the agent must log in to
  that server's master to enumerate databases. With database-scoped credentials
  that requires @refresh_credential_name - but with a managed identity it is
  OMITTED, exactly like the other credential parameters:

      "When using Microsoft Entra authentication, omit the
       @refresh_credential_name parameter. Only for use with credential-based
       authentication."

  Note that server members DO require the UMI to exist in the target server's
  master database, not just in the user database. See 10-target-permissions.sql.
==============================================================================*/
DECLARE @grpAll  nvarchar(128) = N'EHD_AllTargets';
DECLARE @grpProd nvarchar(128) = N'EHD_Prod';

IF NOT EXISTS (SELECT 1 FROM jobs.target_groups WHERE target_group_name = @grpAll)
    EXEC jobs.sp_add_target_group @target_group_name = @grpAll;

IF NOT EXISTS (SELECT 1 FROM jobs.target_groups WHERE target_group_name = @grpProd)
    EXEC jobs.sp_add_target_group @target_group_name = @grpProd;
GO

/*
-- ---------------------------------------------------------------------------
-- 2a. Whole-server membership: every database on the server, automatically.
-- ---------------------------------------------------------------------------
EXEC jobs.sp_add_target_group_member
     @target_group_name      = 'EHD_AllTargets',
     @target_type            = 'SqlServer',
     @server_name            = 'sql-prod-weu.database.windows.net';
     -- no @refresh_credential_name: the agent's managed identity is used

-- ---------------------------------------------------------------------------
-- 2b. EXCLUDE anything that must never be touched. Exclusions win over
--     inclusions, so this is the safe way to protect a sensitive database
--     while still auto-including the rest of the server.
-- ---------------------------------------------------------------------------
EXEC jobs.sp_add_target_group_member
     @target_group_name = 'EHD_AllTargets',
     @membership_type   = 'Exclude',
     @target_type       = 'SqlDatabase',
     @server_name       = 'sql-prod-weu.database.windows.net',
     @database_name     = 'VendorDb_DoNotTouch';

-- ---------------------------------------------------------------------------
-- 2c. Explicit single-database membership - the conservative option, and the
--     right one while you are still agreeing scope with a vendor.
-- ---------------------------------------------------------------------------
EXEC jobs.sp_add_target_group_member
     @target_group_name = 'EHD_Prod',
     @target_type       = 'SqlDatabase',
     @server_name       = 'sql-prod-weu.database.windows.net',
     @database_name     = 'AdventureWorks';
*/
GO


/*==============================================================================
  3. INSPECT WHAT THE GROUPS ACTUALLY RESOLVE TO
     Do this before enabling collection. "Whole server" can be a larger blast
     radius than you expect.
==============================================================================*/
SELECT  g.target_group_name,
        m.membership_type,
        m.target_type,
        m.server_name,
        m.database_name,
        m.refresh_credential_name
FROM    jobs.target_group_members AS m
JOIN    jobs.target_groups        AS g ON g.target_group_id = m.target_group_id
WHERE   g.target_group_name LIKE 'EHD[_]%'
ORDER BY g.target_group_name, m.membership_type DESC, m.server_name, m.database_name;
GO

PRINT '';
PRINT 'Next: 21-jobs-frequent.sql, 22-jobs-standard.sql, 23-jobs-daily.sql';
PRINT 'Then : run tests/verify-staging-schema.sql once data has landed.';
GO
