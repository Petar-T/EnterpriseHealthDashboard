/* Document 1 - Deployment Guide */
const L = require('./doc-lib');
const { H1, H2, H3, P, RICH, RUN, BULLET, NUM, CODE, CALLOUT, TBL, SPACER, BREAK, docShell, save } = L;

const SRV = 'ehd-server.database.windows.net';
const c = [];

/* ------------------------------------------------------------------ intro */
c.push(H1('1. About this document'));
c.push(P('This is the end-to-end procedure for deploying the Enterprise Health Dashboard: a zero-footprint monitoring system for Azure SQL Database. It records the deployment as actually performed, with the real resource names, every verification gate, and the failure modes encountered along the way.'));
c.push(P('Every step has a gate. Do not proceed past a gate that has not passed - several failures in this system are silent by nature, and a skipped gate turns a five-minute fix into an hour of misdirection.'));

c.push(H2('What "zero footprint" means'));
c.push(P('Nothing is created inside a monitored database. No tables, no procedures, no schema changes, no agents, no data access. The system reads dynamic management views only, from a central repository that reaches out to each database on a schedule.'));
c.push(P('This matters when the databases belong to a vendor, are under change control, or carry compliance obligations that make deploying objects into them expensive or impossible.'));

c.push(TBL(
  ['What is created where', 'Monitored databases', 'Central repository'],
  [
    ['Tables / procedures / views', 'none', '27 tables, 22 views, 9 procedures, 3 functions'],
    ['Database principal', 'none, if server-level roles are available', 'one managed-identity user'],
    ['Extended Events sessions', 'optional, opt-in, disabled by default', 'n/a'],
    ['Permissions required', 'read-only DMV access', 'full control (you own it)'],
    ['Data read', 'DMVs only - never table contents', 'n/a']
  ], [34, 33, 33]));

c.push(H2('Architecture in one paragraph'));
c.push(P('An Elastic Job Agent runs read-only queries inside each monitored database on three schedules (5 minutes, 30 minutes, daily). Elastic Jobs lands each result set in a staging table in the central repository. A normalizer promotes staging into a modelled schema, an alert engine evaluates thresholds, and a PowerShell generator renders a single self-contained HTML dashboard. The agent authenticates with a user-assigned managed identity throughout - there are no passwords anywhere in the system.'));

c.push(BREAK());

/* ------------------------------------------------------------ prerequisites */
c.push(H1('2. Before you start'));

c.push(H2('Decisions to make first'));
c.push(TBL(['Decision', 'Options', 'What was chosen here'],
  [
    ['Connectivity', 'Private endpoints (service-managed) or public endpoint with IP firewall', 'Public endpoint for the repository server plus a private endpoint from the agent to each target server'],
    ['Authentication', 'User-assigned managed identity, or database-scoped credentials', 'User-assigned managed identity. Mandatory on Entra-only servers, and the two cannot be mixed within one agent'],
    ['Repository sizing', 'S1 minimum; S2 or higher for an estate', 'S2'],
    ['Target identity model', 'Server-level roles in master (zero footprint) or a contained user per database', 'Server-level roles - nothing is created in the monitored databases']
  ], [22, 45, 33]));

c.push(CALLOUT('Serverless databases cost real money to monitor',
  ['A serverless database polled every five minutes can never auto-pause. A GP_S_Gen5_1 that never pauses costs roughly $190 per month, against near-zero while paused.',
   'Decide this deliberately per database. To reverse it, remove the database from the target group and it will auto-pause again after its configured idle delay.'], 'C07000'));
c.push(SPACER());

c.push(H2('Client tooling'));
c.push(P('The deployment scripts are plain T-SQL and can be run from any client. Two caveats cost real time during this deployment:'));
c.push(TBL(['Client', 'Status', 'Note'],
  [
    ['SSMS', 'Works', 'Turn OFF Always Encrypted parameterization first (section 10). SSMS does NOT reload a file changed on disk - it runs the editor buffer'],
    ['sqlcmd -G', 'Fails for managed accounts', '"WIA can only be used for federated accounts, but this account was Managed"'],
    ['SqlServer PowerShell module', 'Cannot connect on ARM64', 'Its native SNI library has no ARM64 build'],
    ['deploy\\Invoke-EhdSql.py', 'Recommended', 'Token auth via Azure CLI + pyodbc. Reads the file from disk every run, so stale-buffer deployments are impossible']
  ], [26, 24, 50]));

c.push(CALLOUT('Prefer Invoke-EhdSql.py for every deployment',
  ['Three separate failures during this deployment were caused by SSMS running a stale editor buffer after the file had changed on disk. The symptom is always the same and always misleading: the redeploy reports success and the old behaviour persists.',
   'After any redeploy, verify what actually landed: SELECT LEN(OBJECT_DEFINITION(OBJECT_ID(...))) for code, or SELECT LEN(command) FROM jobs.jobsteps for job steps.'], 'C00000'));

c.push(BREAK());

/* -------------------------------------------------------- deployment values */
c.push(H1('3. Deployment values'));
c.push(P('The values used in this deployment. Substitute your own throughout.'));
c.push(TBL(['Item', 'Value'],
  [
    ['Subscription', '<your-subscription>'],
    ['Resource group', 'EnterpriseHealthDashboard'],
    ['Region', 'Central US'],
    ['Logical server', 'ehd-server  (' + SRV + ')'],
    ['Repository database', 'EnterpriseHealth  (S2) - also the Elastic Job Agent job database'],
    ['Elastic Job Agent', 'ehd-agent'],
    ['User-assigned managed identity', 'ehd-agent-umi'],
    ['Entra admin', 'you@your-tenant.com'],
    ['Monitored estate', 'EnterpriseHealth (ehd-server); AdminDb, SalesDb, ReportingDb (sql-shared-01)']
  ], [32, 68]));

c.push(CALLOUT('One database, two roles - and it is supported',
  ['The Elastic Job Agent job database and the monitoring repository are the SAME Azure SQL Database. Microsoft guidance suggests a clean database for an agent, but that is guidance, not a restriction: a job database is an ordinary Azure SQL Database and can host other schemas.',
   'The only genuine 1:1 constraint runs one way - a job database hosts exactly one agent.',
   'Sharing one database is what lets the alert engine explain WHY a feed went stale, because jobs.job_executions is local rather than a cross-database hop.'], '2E5496'));

c.push(BREAK());

/* ------------------------------------------------------------ phase 1 */
c.push(H1('4. Phase 1 - Azure resources'));

c.push(H3('4.1  Resource group and logical server'));
c.push(P('Portal, search for SQL servers (not "SQL databases"), then + Create.'));
c.push(TBL(['Tab', 'Setting'],
  [
    ['Basics', 'Resource group, Server name (globally unique), Location'],
    ['Authentication', 'Use both SQL and Microsoft Entra authentication; Set admin to yourself'],
    ['Networking', 'Add current client IP address = Yes'],
    ['Networking', 'Allow Azure services = No, for now (see 4.5)']
  ], [22, 78]));
c.push(CALLOUT('There is no "Connectivity method" choice when creating a logical server',
  ['That radio button appears when you create a DATABASE, not a server. A server\'s Networking tab offers only the firewall toggles. Public versus private access is set afterwards under Security > Networking on the created server.'], '2E5496'));
c.push(SPACER());

c.push(H3('4.2  The repository database'));
c.push(P('Create a database on that server. S1 is the documented minimum for a job database on the DTU model; S2 was used here.'));
c.push(CALLOUT('Do not use serverless with auto-pause for the repository',
  ['The agent polls it constantly, so it will never pause - you pay the un-paused rate with none of the benefit.'], 'C07000'));
c.push(SPACER());

c.push(H3('4.3  Gate 1 - which connectivity model are you actually on?'));
c.push(...CODE(['az sql server show -g <rg> -n <server> --query "{public:publicNetworkAccess}" -o json']));
c.push(TBL(['Result', 'Meaning'],
  [['Enabled', 'Public endpoint model. Firewall rules apply. Simplest path'],
   ['Disabled', 'Private-only. A private endpoint is mandatory before anything can connect, including you']],
  [22, 78]));
c.push(P('Azure Policy can rewrite this silently. A "modify" effect policy lets creation succeed and then changes the value, so check rather than assume. In this deployment the same policy forced Disabled in North Europe and left Enabled in Central US.'));

c.push(H3('4.4  Gate 2 - can you connect, and is it Azure SQL Database?'));
c.push(...CODE([
  'SELECT db = DB_NAME(), me = SUSER_SNAME(),',
  "       engine = CAST(SERVERPROPERTY('EngineEdition') AS int);"]));
c.push(P('EngineEdition 5 is Azure SQL Database. Anything else means the scripts will not all apply.'));

c.push(H3('4.5  The managed identity and the agent'));
c.push(NUM('Create a user-assigned managed identity (ehd-agent-umi).', 'steps'));
c.push(NUM('Create the Elastic Job Agent against the repository database, attaching that identity at creation time.', 'steps'));
c.push(NUM('Wait for the agent to reach Ready. It creates the jobs and jobs_internal schemas in the database.', 'steps'));
c.push(CALLOUT('az sql elastic-job does not exist',
  ['Azure CLI has no command group for Elastic Job Agents - not in az sql, and not in any extension. Use the portal, ARM REST, or New-AzSqlElasticJobAgent.'], 'C00000'));
c.push(SPACER());

c.push(H3('4.6  Networking for the agent - do not skip this'));
c.push(P('The agent must be able to reach every target server AND the output server. Microsoft, verbatim: "You must create a private endpoint for each desired target server and the job output server."'));
c.push(CALLOUT('The repository\'s own server counts as a target',
  ['Even when the agent, the job database and the repository are all on the SAME logical server, the agent connecting to that server as a TARGET still goes through the firewall or private-endpoint path. Sharing a server buys nothing here.',
   'Skipping this produces: "Failed to connect to the target database: Cannot open server \'<srv>\' requested by the login. Client with IP address \'20.x.x.x\' is not allowed to access the server." The IP is the agent\'s, not yours, and it is not stable - do not allow-list it.'], 'C00000'));
c.push(SPACER());
c.push(P('Two ways to satisfy it:'));
c.push(TBL(['Option', 'How', 'Trade-off'],
  [
    ['Private endpoint (recommended)', 'Agent blade > Private endpoints > Add target server, then approve it on that server under Networking > Private endpoint connections', 'Narrow. Works even when Deny Public Access is on. Takes a few minutes and a two-step approval'],
    ['Firewall rule', "EXEC sp_set_firewall_rule N'AllowAllWindowsAzureIps','0.0.0.0','0.0.0.0' in master", 'Immediate, but admits every Azure subscription in the world - not just yours. Acceptable for a sandbox only']
  ], [24, 46, 30]));

c.push(BREAK());

/* ------------------------------------------------------------ phase 2 */
c.push(H1('5. Phase 2 - the repository schema'));
c.push(P('Seven scripts, in order, against the repository database. Filename order is execution order.'));
c.push(TBL(['#', 'Script', 'Creates'],
  [
    ['1', '01-central\\00-schemas-and-config.sql', 'Schemas cfg / stg / core; cfg.Setting (34 keys); cfg.Target; core.ProcessRun; core.FeedArrival'],
    ['2', '01-central\\01-core-tables.sql', 'The 24 modelled tables and their indexes'],
    ['3', '01-central\\02-normalize.sql', 'core.fn_StagingReady, core.usp_RecordArrival, core.usp_Normalize, core.usp_PurgeStaging'],
    ['4', '01-central\\03-views.sql', 'The analytical views - deltas, scorecard, forecasts, drift'],
    ['5', '01-central\\04-job-health.sql', 'Job-health views. Creates EMPTY STUBS if the jobs schema does not exist yet - re-run after the agent exists'],
    ['6', '01-central\\05-alerts.sql', 'core.usp_RaiseAlert, core.usp_ResolveAlerts, core.usp_EvaluateAlerts, core.AlertHistory'],
    ['7', '01-central\\06-purge.sql', 'core.usp_Purge - retention for the modelled tables']
  ], [6, 38, 56]));

c.push(H3('Gate 3 - object counts'));
c.push(...CODE([
  "SELECT Tables = (SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s",
  "                   ON s.schema_id=t.schema_id WHERE s.name IN ('cfg','core')),",
  "       Views  = (SELECT COUNT(*) FROM sys.views v JOIN sys.schemas s",
  "                   ON s.schema_id=v.schema_id WHERE s.name IN ('cfg','core')),",
  "       Procs  = (SELECT COUNT(*) FROM sys.procedures),",
  "       Funcs  = (SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN','IF','TF')),",
  '       Settings = (SELECT COUNT(*) FROM cfg.Setting);']));
c.push(P('Expected on a complete deployment: 27 tables, 22 views, 9 procedures, 3 functions, 34 settings.'));

c.push(BREAK());

/* ------------------------------------------------------------ phase 3 */
c.push(H1('6. Phase 3 - identity and the privilege boundary'));
c.push(P('Run in the repository database. The managed identity needs enough to land results and run the processing procedures, and must be denied everything else.'));
c.push(...CODE([
  'CREATE USER [ehd-agent-umi] FROM EXTERNAL PROVIDER;',
  '',
  '-- land results here',
  'GRANT CREATE TABLE TO [ehd-agent-umi];',
  'GRANT ALTER ON SCHEMA::stg  TO [ehd-agent-umi];',
  'GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::stg  TO [ehd-agent-umi];',
  'GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::core TO [ehd-agent-umi];',
  'GRANT SELECT  ON SCHEMA::cfg  TO [ehd-agent-umi];',
  'GRANT EXECUTE ON SCHEMA::core TO [ehd-agent-umi];',
  'GRANT VIEW DEFINITION TO [ehd-agent-umi];',
  '',
  '-- READ job history: core.vw_JobHealth -> jobs.job_executions',
  'ALTER ROLE jobs_reader ADD MEMBER [ehd-agent-umi];',
  '',
  '-- only if this database is also a collection target',
  'GRANT VIEW DATABASE STATE TO [ehd-agent-umi];',
  '',
  '-- THE BOUNDARY - note the absence of CONTROL',
  'DENY INSERT, UPDATE, DELETE, ALTER, EXECUTE ON SCHEMA::jobs TO [ehd-agent-umi];',
  'DENY INSERT, UPDATE, DELETE, ALTER, CONTROL ON SCHEMA::jobs_internal TO [ehd-agent-umi];']));

c.push(CALLOUT('Never add CONTROL to the DENY on the jobs schema',
  ['CONTROL implies EVERY permission on a securable, so DENY ... CONTROL also denies SELECT - and DENY beats GRANT and beats role membership.',
   'The result is specific and confusing: normalization keeps working, only alert evaluation dies, and it reads as an alerting bug rather than a permissions one. The error is "The SELECT permission was denied on the object \'job_executions\'".',
   'Deny the specific write permissions instead. It is both narrower and actually correct.'], 'C00000'));
c.push(SPACER());

c.push(H3('Gate 4 - the boundary held, both halves'));
c.push(P('Assert two things, not one. A DENY that is too broad passes a "does a DENY exist?" check while silently breaking the system.'));
c.push(...CODE([
  'SELECT p.state_desc, p.permission_name, SchemaName = s.name',
  'FROM   sys.database_permissions p',
  'JOIN   sys.schemas s ON s.schema_id = p.major_id',
  'WHERE  p.class = 3',
  "  AND  p.grantee_principal_id = DATABASE_PRINCIPAL_ID('ehd-agent-umi')",
  "  AND  s.name IN ('jobs','jobs_internal');",
  '',
  "SELECT IsMember = IS_ROLEMEMBER('jobs_reader','ehd-agent-umi');   -- must be 1"]));
c.push(P('Expected: DENY on INSERT/UPDATE/DELETE/ALTER/EXECUTE for the jobs schema, no DENY on SELECT or CONTROL, and jobs_reader membership = 1.'));

c.push(BREAK());

/* ------------------------------------------------------------ phase 4 */
c.push(H1('7. Phase 4 - the job definitions'));
c.push(P('Six scripts against the repository database, then a re-run of the job-health views. No SQLCMD mode and no -v switches: the server name is a plain T-SQL variable inside each script, validated against the live connection.'));

c.push(TBL(['#', 'Script', 'Creates'],
  [['1', '03-elasticjobs\\20-agent-setup.sql', 'Target groups EHD_AllTargets, EHD_Prod'],
   ['2', '03-elasticjobs\\21-jobs-frequent.sql', 'EHD_Collect_Frequent - 5 steps, every 5 minutes'],
   ['3', '03-elasticjobs\\22-jobs-standard.sql', 'EHD_Collect_Standard - 7 steps, every 30 minutes'],
   ['4', '03-elasticjobs\\23-jobs-daily.sql', 'EHD_Collect_Daily - 6 steps, daily'],
   ['5', '03-elasticjobs\\24-jobs-process.sql', 'EHD_Process_Frequent (2 steps), EHD_Process_Daily (3 steps), target group EHD_Central'],
   ['6', '03-elasticjobs\\25-jobs-setup.sql', 'EHD_Setup_Targets - OPTIONAL, created DISABLED. The only job that writes to a target'],
   ['7', '01-central\\04-job-health.sql', 'RE-RUN - swaps the stub views for live ones now that jobs.job_executions exists']],
  [6, 38, 56]));

c.push(CALLOUT('Disable the collect jobs before any REDEPLOY of step definitions',
  ['Once a target group has members, EHD_Collect_Frequent (5 min) and EHD_Collect_Standard (30 min) fire on their own schedule and will race your redeploy. A job can run with the OLD command text seconds before you replace it, creating stg.* tables with the old shape - and the agent then reuses those tables forever.',
   'EXEC jobs.sp_update_job @job_name = N\'EHD_Collect_Frequent\', @enabled = 0;   -- and the others',
   'If a collection query\'s output columns changed, also DROP the affected stg.* tables so the agent recreates them.'], 'C00000'));
c.push(SPACER());

c.push(H3('Gate 5 - six jobs, 25 steps'));
c.push(...CODE([
  'SELECT j.job_name, j.enabled, j.schedule_interval_type, j.schedule_interval_count,',
  '       Steps = (SELECT COUNT(*) FROM jobs.jobsteps s',
  '                WHERE s.job_id = j.job_id AND s.job_version = j.job_version)',
  "FROM   jobs.jobs j WHERE j.job_name LIKE 'EHD[_]%' ORDER BY j.job_name;"]));
c.push(TBL(['Job', 'Enabled', 'Schedule', 'Steps'],
  L.inv.jobs.map(j => [j.name, j.enabled === '0' ? '0 (by design)' : '1',
    j.intervalType === '(none)' ? 'none - manual only' : (j.intervalType + ' ' + j.intervalCount),
    String(j.steps.length)]), [34, 18, 30, 18]));

c.push(BREAK());

/* ------------------------------------------------------------ phase 5 */
c.push(H1('8. Phase 5 - the first target'));
c.push(P('The safest first target is the repository database itself: an estate of one, a database you own, where a mistake costs nothing. Full detail for any subsequent database is in the companion document, "Adding a Monitored Database".'));

c.push(...CODE([
  '-- 1. the collection permission (this database is now also a target)',
  'GRANT VIEW DATABASE STATE TO [ehd-agent-umi];',
  '',
  '-- 2. register it',
  'EXEC jobs.sp_add_target_group_member',
  "     @target_group_name = N'EHD_AllTargets',",
  "     @membership_type   = N'Include',",
  "     @target_type       = N'SqlDatabase',",
  "     @server_name       = N'" + SRV + "',",
  "     @database_name     = N'EnterpriseHealth';"]));

c.push(H3('Gate 6 - the group is not empty'));
c.push(P('This gate exists because of the worst failure mode in the system: a collect job whose target group is empty SUCCEEDS, forever, collecting nothing. Every step reports "Step N succeeded" - vacuously true, having run zero times.'));
c.push(...CODE([
  'SELECT g.target_group_name, m.membership_type, m.target_type,',
  '       m.server_name, m.database_name',
  'FROM   jobs.target_group_members m',
  'JOIN   jobs.target_groups g ON g.target_group_id = m.target_group_id',
  "WHERE  g.target_group_name LIKE 'EHD[_]%';"]));

c.push(H3('Gate 7 - the job reached a real database'));
c.push(...CODE([
  "EXEC jobs.sp_start_job @job_name = N'EHD_Collect_Frequent';",
  '-- wait ~90 seconds',
  'SELECT step_name, target_database_name, lifecycle, last_message',
  'FROM   jobs.job_executions',
  "WHERE  job_name = N'EHD_Collect_Frequent'",
  '  AND  target_database_name IS NOT NULL',
  'ORDER BY create_time DESC;']));
c.push(CALLOUT('target_database_name is the tell',
  ['Rows where target_type, target_server_name and target_database_name are all NULL are step-level roll-ups. If there are NO rows with target_database_name populated, the job ran against zero databases no matter what lifecycle says.'], '2E5496'));
c.push(SPACER());

c.push(H3('Gate 8 - the staging contract'));
c.push(P('Run tests\\verify-staging-schema.sql. This checks the one assumption the build cannot verify at compile time.'));
c.push(CALLOUT('Elastic Jobs adds exactly ONE column to an output table',
  ['internal_execution_id uniqueidentifier, plus a nonclustered index on it. That is all.',
   'It does NOT add last_modify_time, target_server_name or target_database_name. Those last two belong to the jobs.job_executions CATALOG VIEW, which is a different object entirely. Conflating the two produced three separate defects during this deployment.',
   'Every collection query therefore emits its own identity and timestamp: ServerName = CAST(@@SERVERNAME AS nvarchar(256)), DatabaseName = DB_NAME(), SnapshotUtc = ...'], 'C00000'));
c.push(SPACER());

c.push(H3('Gate 9 - end to end'));
c.push(...CODE([
  'EXEC core.usp_Normalize @Debug = 1;',
  'EXEC core.usp_EvaluateAlerts;',
  '',
  'SELECT ServerName, DatabaseName, FeedName, Tier, LastArrivalUtc, LastRowCount',
  'FROM   core.FeedArrival ORDER BY ServerName, DatabaseName, FeedName;',
  '',
  'SELECT TOP 10 ProcessRunId, StepName, Status, RowsAffected, ErrorMessage',
  'FROM   core.ProcessRun ORDER BY ProcessRunId DESC;']));
c.push(P('core.FeedArrival must have a row per database and feed. If core.* has rows but FeedArrival is empty, the dashboard will show every database as NO DATA while the data path looks perfect from SQL.'));

c.push(BREAK());

/* ------------------------------------------------------------ phase 6 */
c.push(H1('9. Phase 6 - the dashboard'));
c.push(...CODE([
  '.\\04-dashboard\\New-EnterpriseDashboard.ps1 `',
  '    -CentralServer   ' + SRV + ' `',
  '    -CentralDatabase EnterpriseHealth `',
  '    -OutputPath      .\\04-dashboard\\estate.html']));
c.push(P('The generator opens ONE connection to the repository and contacts no monitored database. A target being unreachable does not break generation - it appears as a collection state of CRITICAL.'));
c.push(P('Authentication prefers an Entra token acquired from the Azure CLI over "Authentication=Active Directory Default", because the latter routes through Azure.Identity, whose dependency chain is frequently incomplete. The observed failure is "AzureCliCredential authentication failed: Could not load file or assembly \'System.IO.Pipelines\'" - a packaging problem in the client that no amount of re-authenticating will fix.'));
c.push(P('Point -OutputPath at a file other than dashboard.html to keep the shipped template pristine for future regeneration.'));

c.push(BREAK());

/* ------------------------------------------------------- troubleshooting */
c.push(H1('10. Troubleshooting'));
c.push(P('Every entry below was encountered during this deployment. The common thread is that most of these failures are silent or misleadingly reported.'));

c.push(TBL(['Symptom', 'Cause', 'Fix'],
  [
    ['Job says Succeeded but stg.* tables never appear; target_database_name NULL on every execution row',
     'The target group is empty. The job ran zero times and reported success',
     'Add the member, then re-run. Gate 6'],
    ['Cannot open server \'<srv>\' requested by the login. Client with IP address \'20.x.x.x\' is not allowed',
     'The agent\'s own IP is blocked. Your client-IP rule covers your laptop, not the agent. Applies even when the agent and target share a server',
     'Elastic jobs private endpoint, or AllowAllWindowsAzureIps. Never allow-list the agent IP - it is not stable'],
    ['Failed to connect to the target database: Object reference not set to an instance of an object',
     'The target is a serverless database that was auto-paused',
     'The attempt itself wakes it. Confirm status is Online and re-run'],
    ['Login failed for user \'<token-identified principal>\'',
     'The client is pointed at a database that does not exist on THIS server - a default carried over from a previous connection. Azure SQL reports a missing database under Entra auth as a LOGIN failure',
     'Set the connect-to database to master, or one that exists there'],
    ['The SELECT permission was denied on the object \'job_executions\'. Normalize succeeds, EvaluateAlerts fails',
     'DENY ... CONTROL on the jobs schema also denies SELECT. Ownership chaining does not cross schemas owned by different principals',
     'REVOKE CONTROL ON SCHEMA::jobs, and ALTER ROLE jobs_reader ADD MEMBER'],
    ['Several feeds missing, and one earlier step in the same job failed',
     'A failed step ABORTS the remaining steps in that job. Steps 4-7 never run if step 3 fails',
     'Fix the FIRST failing step. Diagnose by step_id, not by which table is missing'],
    ['Invalid object name \'sys.dm_...\' despite the reference sitting inside BEGIN TRY',
     'Binding errors are raised at COMPILE time, before the TRY block is entered. TRY/CATCH cannot catch them',
     'Guard with OBJECT_ID(...) IS NOT NULL and defer the bind through sp_executesql'],
    ['A redeploy appears to do nothing - LEN(command) or OBJECT_DEFINITION unchanged',
     'SSMS does not reload a file changed on disk; F5 runs the stale editor buffer',
     'Close the tab and reopen, or deploy with Invoke-EhdSql.py. Always verify the deployed length'],
    ['Some stg.* tables have new columns, others do not, after a redeploy',
     'An enabled collect job fired on schedule DURING the redeploy and used the old command text',
     'Disable the collect jobs, DROP the stale stg.* tables, redeploy, re-enable'],
    ['Incorrect syntax near the keyword \'OR\' on a CREATE OR ALTER, plus sp_describe_parameter_encryption errors',
     'SSMS Always Encrypted parameterization rewrites DECLARE @x = <literal> into parameters. Reported line numbers refer to the rewritten batch, not your file',
     'Query Options > Execution > Advanced > uncheck Enable Parameterization for Always Encrypted'],
    ['CREATE INDEX failed ... QUOTED_IDENTIFIER',
     'sqlcmd.exe defaults QUOTED_IDENTIFIER to OFF, which breaks filtered indexes',
     'Every shipped script sets it explicitly. Add SET QUOTED_IDENTIFIER ON to your own'],
    ['Every database shows NO DATA although core.* has rows',
     'core.FeedArrival is empty - arrival tracking failed and the error was swallowed',
     'Check core.ProcessRun for RecordArrival:* rows. Confirm each stg table has a recognised timestamp column']
  ], [30, 36, 34]));

c.push(BREAK());

/* ------------------------------------------------------------ operations */
c.push(H1('11. Day-2 operations'));

c.push(H3('Every morning - 30 seconds'));
c.push(...CODE([
  'SELECT * FROM core.vw_OpenAlerts ORDER BY Severity, RaisedUtc DESC;',
  'SELECT * FROM core.vw_FeedDiagnosis WHERE CollectionState <> \'OK\';']));

c.push(H3('Weekly'));
c.push(BULLET('core.vw_CapacityForecast - anything running out of space inside 90 days'));
c.push(BULLET('core.vw_UnusedIndexes and core.vw_MissingIndexTop - index hygiene'));
c.push(BULLET('core.vw_QueryRegression - plan changes that made something slower'));
c.push(BULLET('core.vw_SecurityDrift - principals and permissions that changed'));

c.push(H3('Monthly'));
c.push(BULLET('Confirm retention is actually running: EXEC core.usp_Purge and EXEC core.usp_PurgeStaging both report rows deleted'));
c.push(BULLET('Review repository size against the growth you expected'));
c.push(BULLET('Re-run tests\\verify-staging-schema.sql after any agent upgrade'));

c.push(CALLOUT('Verify that retention is running, do not assume it',
  ['usp_PurgeStaging originally filtered for a column that no staging table has. The cursor matched zero tables, the procedure reported success with an empty result set, and staging grew without bound indefinitely.',
   'A purge that reports success and an empty result set is indistinguishable from a purge with nothing to do. Check row counts in stg.* over time.'], 'C00000'));

c.push(H3('Removing a database from monitoring'));
c.push(...CODE([
  'EXEC jobs.sp_delete_target_group_member',
  "     @target_group_name = N'EHD_AllTargets',",
  '     @target_id = <from jobs.target_group_members>;',
  '',
  "UPDATE cfg.Target SET IsEnabled = 0 WHERE DatabaseName = N'<db>';"]));
c.push(P('Historic data is retained and ages out under the normal retention settings. For a serverless database this also lets it auto-pause again.'));

(async () => {
  await save(docShell('Enterprise Health Dashboard', 'Deployment Guide', c),
             'EHD-01-Deployment-Guide.docx');
})();
