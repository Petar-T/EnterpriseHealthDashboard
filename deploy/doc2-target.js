/* Document 2 - Adding a Monitored Database */
const L = require('./doc-lib');
const { H1, H2, H3, P, BULLET, NUM, CODE, CALLOUT, TBL, SPACER, BREAK, docShell, save } = L;
const c = [];

c.push(H1('1. What this covers'));
c.push(P('The procedure for bringing an additional Azure SQL Database under monitoring, from an estate of one to an estate of many. It assumes the Enterprise Health Dashboard is already deployed and collecting - see the companion Deployment Guide if not.'));
c.push(P('Onboarding is four steps, and three of them are about reaching the database rather than monitoring it:'));
c.push(TBL(['Step', 'What', 'Where it runs'],
  [
    ['1', 'Networking - the agent must be able to reach the target server', 'Azure portal'],
    ['2', 'Identity - the collector must be able to log in and read DMVs', "The target server's master, or the target database"],
    ['3', 'Registration - add the database to a target group', 'The repository database'],
    ['4', 'Verification - prove data actually arrived', 'The repository database']
  ], [8, 56, 36]));

c.push(H2('What gets created in the monitored database'));
c.push(CALLOUT('Nothing, on the recommended path',
  ['With server-level roles, the collector identity lives entirely in the target server\'s master database - which you own - and nothing at all is created inside the monitored database. No user, no schema object, no Extended Events session.',
   'This is the answer to "we are not permitted to deploy anything into that database".'], '2E5496'));
c.push(SPACER());

c.push(BREAK());

/* ------------------------------------------------------------ decisions */
c.push(H1('2. Four questions to answer first'));

c.push(H3('2.1  Is the target server reachable by the agent?'));
c.push(...CODE(['az sql server show -g <rg> -n <server> --query "{public:publicNetworkAccess}" -o json']));
c.push(TBL(['Result', 'What you need'],
  [['Enabled', 'An elastic jobs private endpoint, OR the AllowAllWindowsAzureIps firewall rule'],
   ['Disabled', 'An elastic jobs private endpoint. There is no alternative - firewall rules do not apply when public access is denied']],
  [18, 82]));

c.push(H3('2.2  Is the server Entra-only?'));
c.push(...CODE(['az sql server ad-only-auth get -g <rg> -n <server> -o json']));
c.push(P('If azureAdOnlyAuthentication is true, SQL logins are illegal on that server: CREATE LOGIN ... WITH PASSWORD and CREATE USER ... WITH PASSWORD are rejected outright. The managed identity path is then the only option - which is what this system uses anyway.'));
c.push(CALLOUT('Elastic jobs DO work against Entra-only servers',
  ['Some Microsoft documentation lists elastic jobs as unsupported when Microsoft Entra-only authentication is enabled. That was tested directly during this deployment: three databases on an Entra-only server (azureAdOnlyAuthentication = true) collect successfully using a user-assigned managed identity.',
   'Treat the documentation note with caution rather than as a blocker, but verify in your own tenant.'], '2E5496'));
c.push(SPACER());

c.push(H3('2.3  Is it serverless, and do you accept the cost?'));
c.push(...CODE([
  'az sql db show -g <rg> -s <server> -n <db> \\',
  '  --query "{sku:currentServiceObjectiveName, status:status, pause:autoPauseDelay}" -o json']));
c.push(CALLOUT('Monitoring a serverless database prevents it from ever auto-pausing',
  ['A five-minute collection schedule keeps the database permanently online. A GP_S_Gen5_1 that never pauses costs roughly $190 per month against near-zero while paused.',
   'If the database currently shows status "Paused", onboarding it will wake it and keep it awake. Decide deliberately.',
   'This is fully reversible: remove it from the target group and it auto-pauses again after its idle delay.'], 'C07000'));
c.push(SPACER());

c.push(H3('2.4  One database, or the whole server?'));
c.push(TBL(['Membership', 'Behaviour', 'Use when'],
  [
    ['SqlDatabase (explicit)', 'Exactly the databases you name. Nothing is picked up automatically', 'Agreeing scope with a vendor, or when master must not be included'],
    ['SqlServer (whole server)', 'Dynamically enumerated at every run - new databases are monitored automatically, with no job change', 'You own the server and want new databases covered by default'],
    ['Exclude', 'Wins over any Include. The safe way to protect one database while auto-including the rest', 'A sensitive or vendor-owned database on an otherwise-included server']
  ], [24, 46, 30]));
c.push(P('A whole-server member additionally requires the collector identity to exist as a LOGIN in that server\'s master, because the agent connects there to enumerate the databases.'));

c.push(BREAK());

/* ------------------------------------------------------------- step 1 */
c.push(H1('3. Step 1 - Networking'));
c.push(H3('Preferred: elastic jobs private endpoint'));
c.push(NUM('Portal > the Elastic Job Agent (ehd-agent) > Private endpoints > + Add.', 'steps'));
c.push(NUM('Select the target logical server. The connection status becomes Pending.', 'steps'));
c.push(NUM('Portal > the TARGET server > Networking > Private endpoint connections > select the pending request > Approve.', 'steps'));
c.push(NUM('Confirm it reads Approved on both sides before continuing.', 'steps'));
c.push(P('These are service-managed endpoints: Microsoft creates and operates them, and you supply no VNet, subnet or DNS for this hop. One per target logical server, not per database.'));

c.push(H3('Alternative: firewall rule'));
c.push(...CODE(["-- in master on the TARGET server",
             "EXEC sp_set_firewall_rule N'AllowAllWindowsAzureIps', '0.0.0.0', '0.0.0.0';"]));
c.push(P('Portal equivalent: Networking > Public access > "Allow Azure services and resources to access this server". Understand what this is: it admits every Azure subscription in the world, not only yours. Acceptable for a sandbox; not for a production server holding customer data.'));

c.push(CALLOUT('Do not allow-list the agent IP',
  ['The agent\'s outbound address is not stable. Chasing it produces a rule that works today and fails silently later.'], 'C00000'));
c.push(SPACER());

c.push(H3('Gate 1'));
c.push(P('Private endpoint reads Approved, or the firewall rule exists. Allow up to five minutes for either change to take effect.'));

c.push(BREAK());

/* ------------------------------------------------------------- step 2 */
c.push(H1('4. Step 2 - The collector identity'));

c.push(H2('Option A - server-level roles (recommended, zero footprint)'));
c.push(P('Run once per target LOGICAL SERVER, in its master database, signed in as the Entra admin for that server.'));
c.push(...CODE([
  'CREATE LOGIN [ehd-agent-umi] FROM EXTERNAL PROVIDER;',
  '',
  '-- CONNECT to any database without needing a user in it',
  'ALTER SERVER ROLE ##MS_DatabaseConnector## ADD MEMBER [ehd-agent-umi];',
  '',
  '-- read the DMVs',
  'ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [ehd-agent-umi];',
  '',
  '-- metadata visibility: sys.tables, sys.indexes, OBJECT_NAME, Query Store',
  'ALTER SERVER ROLE ##MS_DefinitionReader##  ADD MEMBER [ehd-agent-umi];']));

c.push(CALLOUT('All three roles are required, and the easiest one to miss is the connector',
  ['##MS_ServerStateReader## and ##MS_DefinitionReader## grant the right to READ once you are inside a database. Neither grants the right to GET inside one.',
   'Without ##MS_DatabaseConnector##, every target fails at login with "Cannot open database ... requested by the login", which reads like a firewall or naming problem and is neither.',
   'Without ##MS_DefinitionReader##, sys.tables and sys.indexes return NOTHING rather than erroring - so the Daily feeds come back silently empty and the database looks like it has no tables.'], 'C00000'));
c.push(SPACER());

c.push(H3('Gate 2 - expect exactly three rows'));
c.push(...CODE([
  'SELECT MemberName = m.name, RoleName = r.name',
  'FROM   sys.server_role_members AS rm',
  'JOIN   sys.server_principals   AS r ON r.principal_id = rm.role_principal_id',
  'JOIN   sys.server_principals   AS m ON m.principal_id = rm.member_principal_id',
  "WHERE  m.name = 'ehd-agent-umi' ORDER BY r.name;"]));

c.push(H2('Option B - a contained user per database'));
c.push(P('Only when the server-level roles are unavailable. This DOES create a principal in the monitored database - a principal, not a schema object, which is usually acceptable, but agree it first.'));
c.push(...CODE([
  '-- in EACH target database',
  'CREATE USER [ehd-agent-umi] FROM EXTERNAL PROVIDER;',
  'GRANT VIEW DATABASE STATE TO [ehd-agent-umi];   -- DMVs',
  'GRANT VIEW DEFINITION     TO [ehd-agent-umi];   -- object names']));
c.push(P('Deliberately NOT granted under either option: db_datareader, any CREATE or ALTER on their objects, and any access to table contents. VIEW DATABASE STATE exposes DMVs only.'));

c.push(BREAK());

/* ------------------------------------------------------------- step 3 */
c.push(H1('5. Step 3 - Register the database'));
c.push(P('Run in the repository database.'));
c.push(...CODE([
  'EXEC jobs.sp_add_target_group_member',
  "     @target_group_name = N'EHD_AllTargets',",
  "     @membership_type   = N'Include',",
  "     @target_type       = N'SqlDatabase',",
  "     @server_name       = N'<server>.database.windows.net',",
  "     @database_name     = N'<database>';"]));
c.push(P('No credential argument: the agent authenticates as its managed identity. Supplying @refresh_credential_name would be an error - an agent cannot mix credential types.'));

c.push(H3('Whole server, minus exceptions'));
c.push(...CODE([
  'EXEC jobs.sp_add_target_group_member',
  "     @target_group_name = N'EHD_AllTargets', @membership_type = N'Include',",
  "     @target_type = N'SqlServer', @server_name = N'<server>.database.windows.net';",
  '',
  '-- exclusions win over inclusions',
  "EXEC jobs.sp_add_target_group_member 'EHD_AllTargets', 'Exclude',",
  "     'SqlDatabase', '<server>.database.windows.net', 'VendorDb_DoNotTouch';"]));

c.push(H3('Gate 3 - the group is not empty'));
c.push(...CODE([
  'SELECT g.target_group_name, m.membership_type, m.target_type,',
  '       m.server_name, m.database_name',
  'FROM   jobs.target_group_members m',
  'JOIN   jobs.target_groups g ON g.target_group_id = m.target_group_id',
  "WHERE  g.target_group_name LIKE 'EHD[_]%'",
  'ORDER BY m.server_name, m.database_name;']));
c.push(CALLOUT('Do not skip this gate',
  ['A collect job whose target group is empty reports SUCCESS - forever - while collecting nothing. Every step logs "Step N succeeded", which is vacuously true: the step completed, zero times.',
   'This is the single most misleading failure in the system. Confirm the member row exists before running anything.'], 'C00000'));

c.push(BREAK());

/* ------------------------------------------------------------- step 4 */
c.push(H1('6. Step 4 - Verify'));
c.push(...CODE(["EXEC jobs.sp_start_job @job_name = N'EHD_Collect_Frequent';"]));
c.push(P('Wait roughly 90 seconds per target, then:'));
c.push(...CODE([
  'SELECT target_database_name, step_name, lifecycle, last_message',
  'FROM   jobs.job_executions',
  "WHERE  job_name = N'EHD_Collect_Frequent'",
  '  AND  target_database_name IS NOT NULL',
  '  AND  start_time > DATEADD(MINUTE, -15, SYSUTCDATETIME())',
  'ORDER BY target_database_name, step_name;']));
c.push(P('You want five rows per database, all Succeeded. Rows where target_database_name is NULL are step-level roll-ups, not per-target results.'));

c.push(H3('Then the Standard and Daily tiers'));
c.push(P('A new database has never seen them, and Daily would otherwise wait until its next scheduled run.'));
c.push(...CODE([
  "EXEC jobs.sp_start_job @job_name = N'EHD_Collect_Standard';   -- wait ~3 min",
  "EXEC jobs.sp_start_job @job_name = N'EHD_Collect_Daily';      -- wait ~3 min",
  'EXEC core.usp_Normalize @Debug = 1;',
  'EXEC core.usp_EvaluateAlerts;']));

c.push(H3('Gate 4 - data actually arrived'));
c.push(...CODE([
  'SELECT ServerName, DatabaseName, FeedName, Tier, LastArrivalUtc, LastRowCount',
  'FROM   core.FeedArrival',
  "WHERE  DatabaseName = N'<database>'",
  'ORDER BY Tier, FeedName;']));
c.push(P('Expect roughly 12 to 18 feed rows. Some feeds legitimately produce none: the XE feeds have nothing until EHD_Setup_Targets is run, and BlockingChain, MissingIndex and IndexFragmentation are often empty on a small or idle database.'));
c.push(P('core.FeedArrival is what the dashboard reads for freshness. If core.* has rows but FeedArrival is empty, every database shows NO DATA while the data path looks perfect from SQL.'));

c.push(H3('Then regenerate the dashboard'));
c.push(...CODE([
  '.\\04-dashboard\\New-EnterpriseDashboard.ps1 `',
  '    -CentralServer   ehd-server.database.windows.net `',
  '    -CentralDatabase EnterpriseHealth `',
  '    -OutputPath      .\\04-dashboard\\estate.html']));

c.push(BREAK());

/* ------------------------------------------------------------ optional */
c.push(H1('7. Optional - target-side setup'));
c.push(P('EHD_Setup_Targets deploys two Extended Events sessions and right-sizes Query Store on each target. It is the ONLY job in the system that writes to a monitored database, and it is created disabled and unscheduled on purpose.'));
c.push(TBL(['What it changes', 'What it never does'],
  [['Two XE sessions (ring buffer only, no file target)', 'No tables, no procedures, no schema changes'],
   ['Query Store enabled and sized - never downgraded if already better', 'No data access of any kind']],
  [50, 50]));
c.push(P('It requires ALTER ANY DATABASE EVENT SESSION on the target, which the read-only roles do not grant. Run it by hand, once, after the database owner has agreed:'));
c.push(...CODE(["EXEC jobs.sp_start_job @job_name = N'EHD_Setup_Targets';"]));
c.push(P('Without it, the XE feeds return nothing and everything else works normally. The blocking coverage gap this leaves is real but narrow: a blocking chain that starts and finishes between two five-minute polls is invisible without the XE session.'));

c.push(BREAK());

/* ------------------------------------------------------------ removal */
c.push(H1('8. Removing a database from monitoring'));
c.push(...CODE([
  '-- find the member id',
  'SELECT m.target_id, m.server_name, m.database_name',
  'FROM   jobs.target_group_members m',
  'JOIN   jobs.target_groups g ON g.target_group_id = m.target_group_id',
  "WHERE  g.target_group_name = N'EHD_AllTargets';",
  '',
  'EXEC jobs.sp_delete_target_group_member',
  "     @target_group_name = N'EHD_AllTargets', @target_id = <target_id>;",
  '',
  '-- stop it appearing on the dashboard as stale',
  "UPDATE cfg.Target SET IsEnabled = 0 WHERE DatabaseName = N'<database>';"]));
c.push(P('Historic data is kept and ages out under the normal retention settings. For a serverless database, removal also restores its ability to auto-pause.'));
c.push(P('To remove the system entirely from a target server, drop the login from master. If Option B was used, drop the user from each database. If EHD_Setup_Targets was ever run there, drop the two XE sessions.'));

c.push(BREAK());

/* ------------------------------------------------------ worked example */
c.push(H1('9. Worked example'));
c.push(P('Three databases on sql-shared-01, added to an existing deployment. The server was private-only and Entra-only, which exercised every awkward path at once.'));
c.push(TBL(['Property', 'Value'],
  [['Server', 'sql-shared-01.database.windows.net'],
   ['publicNetworkAccess', 'Disabled - private endpoint mandatory'],
   ['azureAdOnlyAuthentication', 'true - managed identity mandatory'],
   ['Databases', 'AdminDb (S0), SalesDb (GP_S_Gen5_1, paused), ReportingDb (GP_S_Gen5_1)'],
   ['Footprint created in them', 'none']], [30, 70]));

c.push(H3('What happened'));
c.push(BULLET('Private endpoint from the agent to the server, approved on the server. Status Approved.'));
c.push(BULLET('Three server-role memberships in that server\'s master. Nothing created in the three databases.'));
c.push(BULLET('Three explicit SqlDatabase members added - not a whole-server member, to keep master out.'));
c.push(BULLET('First collection: AdminDb and ReportingDb succeeded on all five steps.'));
c.push(BULLET('SalesDb failed its first attempt with "Object reference not set to an instance of an object" - it was auto-paused. The attempt itself resumed it, and the next run succeeded.'));
c.push(BULLET('Result: 45 rows in core.FeedArrival across four databases and two servers.'));

c.push(BREAK());

/* ------------------------------------------------- troubleshooting */
c.push(H1('10. Troubleshooting a new target'));
c.push(TBL(['Symptom', 'Cause', 'Fix'],
  [
    ['Job succeeds, no stg.* rows, target_database_name NULL everywhere',
     'The target group is empty', 'Confirm the member row exists. Gate 3'],
    ['Cannot open database ... requested by the login',
     '##MS_DatabaseConnector## membership missing', 'Add it in that server\'s master'],
    ['Cannot open server ... Client with IP address 20.x.x.x is not allowed',
     'Networking: no private endpoint and no Azure-services rule',
     'Step 1. The IP is the agent\'s and is not stable'],
    ['Object reference not set to an instance of an object',
     'The target is a paused serverless database',
     'The attempt wakes it; re-run. Confirm status is Online'],
    ['Connection was denied ... Deny Public Network Access is set to Yes (47073)',
     'You are connecting from outside the private path',
     'Run from a VNet-connected host, or re-enable public access with an IP rule'],
    ['Login failed for user \'<token-identified principal>\'',
     'Your client is pointed at a database that does not exist on THIS server',
     'Set the connect-to database to master'],
    ['Daily feeds arrive empty; sys.tables appears to have no rows',
     '##MS_DefinitionReader## membership missing - metadata is hidden, not denied',
     'Add it in that server\'s master'],
    ['Only some feeds appear, and an earlier step in that job failed',
     'A failed step aborts the remaining steps in the job',
     'Fix the first failing step, ordered by step_id']
  ], [32, 34, 34]));

(async () => {
  await save(docShell('Enterprise Health Dashboard', 'Adding a Monitored Database', c),
             'EHD-02-Add-A-Target.docx');
})();
