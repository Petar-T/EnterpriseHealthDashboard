# Deploy and Operate — Enterprise Health Dashboard

> **Legacy extended operator reference.** The current, followable deployment path
> is **[../PORTAL-DEPLOY.md](../PORTAL-DEPLOY.md)**, and database onboarding is
> **[../PORTAL-ADD-DATABASE.md](../PORTAL-ADD-DATABASE.md)**. This file is kept
> for background, design rationale, incident runbooks and troubleshooting history.
> If a procedural step here disagrees with either Portal guide, the Portal guide
> wins.

Operational runbook. `README.md` explains *what* the system is and *why* it is
built this way; this document is the extended reference you keep open when you
need detail beyond the Portal walkthroughs.

**Contents**

1. [Before you start](#1-before-you-start)
2. [Provision the Azure resources](#2-provision-the-azure-resources)
3. [Deploy the repository schema](#3-deploy-the-repository-schema)
4. [Create the collector identity](#4-create-the-collector-identity)
5. [Deploy the jobs](#5-deploy-the-jobs)
6. [Optional: target-side setup](#6-optional-target-side-setup)
7. [Onboard your first database](#7-onboard-your-first-database)
8. [The verification gate](#8-the-verification-gate)
9. [Publish the dashboard](#9-publish-the-dashboard)
10. [Day-2 operations](#10-day-2-operations)
11. [Tuning](#11-tuning)
12. [Troubleshooting](#12-troubleshooting)
13. [Incident runbooks](#13-incident-runbooks)
14. [Upgrade, rollback, offboard](#14-upgrade-rollback-offboard)
15. [Reference](#15-reference)

---

## 1. Before you start

### Decide your connectivity model FIRST

This is the decision everything else hangs off, so make it deliberately rather
than discovering it halfway through.

**Elastic Jobs does not need public network access.** Microsoft is explicit:

> "It is not necessary to enable Public access for the purpose of elastic jobs."
> — [Elastic jobs tutorial](https://learn.microsoft.com/en-us/azure/azure-sql/database/elastic-jobs-tutorial?view=azuresql)

The job agent reaches each target through a **service-managed private endpoint**
that Microsoft creates and operates for you. You do not supply a VNet for that
hop, and it replaces the `AllowAllWindowsAzureIps` 0.0.0.0 firewall rule — which
is the better outcome anyway, since that rule admits traffic from every Azure
tenant, not just yours.

So there are two viable models:

| | **A — Private (recommended)** | **B — Public endpoint** |
|---|---|---|
| Target servers | private endpoint per logical server, created from the job agent blade | `AllowAllWindowsAzureIps` firewall rule |
| Repository server | `publicNetworkAccess = Disabled`, private endpoint in your VNet | public endpoint + IP firewall rules |
| Deploying the schema | from a host inside the VNet (VM + Bastion, VPN, ExpressRoute) | from your workstation |
| Generating the dashboard | scheduled on a VNet-connected host | anywhere |
| Needs a VNet | yes, for *your* access only | no |
| Works where policy forces private-only | **yes** | no |

**Model A is the right default.** Choose B only if you have an unrestricted
subscription and want the shortest path to a demo.

### If your tenant forces private-only

Many tenants assign a policy that forces `publicNetworkAccess = Disabled` on
every Azure SQL server. It is usually a `modify` effect, which means it does not
block anything — it silently rewrites your request and lets creation succeed:

```bash
az sql server create ... --enable-public-network true   # returns "Ready"
az sql server show    ... --query publicNetworkAccess   # returns "Disabled"
```

Attempts to change it afterwards are accepted and then reverted. To confirm it
is a policy rather than a mistake:

```bash
az rest --method post --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Sql/servers/ehd-server/providers/Microsoft.PolicyInsights/policyEvents/default/queryResults?api-version=2019-10-01"
```

A row with `policyDefinitionAction = modify` naming something like
`AzureSQL_PublicNetwork_Modify` confirms it.

**This is not a blocker.** It is the tenant steering you to Model A, which is
where this system should be anyway. Follow Model A and carry on.

The two symptoms you will see if you try to fight it:

```
(DenyPublicEndpointEnabled) Unable to create or modify firewall rules when
public network interface for the server is disabled.
```
```
Connection was denied because Deny Public Network Access is set to Yes. (47073)
```

> The policy applies on **update** as well as create. Running
> `az sql server update` against an existing server that still has public access
> enabled may flip it to `Disabled` and break whatever depends on it. Check
> before you touch unrelated servers.

### Is the server Entra-only?

```bash
az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Sql/servers/ehd-server/azureADOnlyAuthentications/Default?api-version=2023-05-01-preview"
```

If `azureADOnlyAuthentication` is `true`, then **every `CREATE LOGIN ... WITH
PASSWORD`, `CREATE USER ... WITH PASSWORD` and `DATABASE SCOPED CREDENTIAL ...
SECRET` in section 4 is illegal on that server.** You must use a user-assigned
managed identity for the job agent instead. See
[Entra-only estates](#entra-only-estates-managed-identity).

### Does your SQL client actually work?

Do not assume. On some workstations none of the usual clients connect:

| Client | Known failure |
|---|---|
| `Invoke-Sqlcmd` (SqlServer module) | `The type initializer for 'Microsoft.Data.SqlClient.TdsParser' threw an exception` — no native SNI build for the host architecture, e.g. ARM64 |
| `sqlcmd -G` | `WIA can only be used for federated accounts, but this account was Managed` — defaults to integrated auth |
| `sqlcmd -E` to a local box | `SSL Provider: The certificate chain was issued by an authority that is not trusted` — add `-C` |
| **SSMS with Always Encrypted on** | rewrites `DECLARE @x = <literal>` into parameters and fails the DDL with `Incorrect syntax near the keyword 'OR'`. Turn off **Query Options → Execution → Advanced → Enable Parameterization for Always Encrypted** before you start |

`deploy\Invoke-EhdSql.py` is shipped for exactly this case: it mints a token
with the Azure CLI and passes it straight to ODBC Driver 18, bypassing all
three problems. It supports `GO` batching, `$(var)` substitution and `PRINT`
output.

```bash
pip install pyodbc
python deploy\Invoke-EhdSql.py -S ehd-server -d <database> -Q "SELECT SUSER_SNAME()"
```

### What you need

| Item | Detail |
|---|---|
| Azure subscription | Permission to create a SQL database and an Elastic Job Agent |
| **One** Azure SQL Database | Hosts both the Elastic Job Agent and the repository. **S1 minimum** (the agent requires S1+ on the DTU model), **S2 / GP_Gen5_2 recommended.** Size it for the collected history — the agent's own footprint is negligible. **Serverless with auto-pause is not supported** as a job database |
| Model A only: a VNet | For *your* access to the repository. The job-agent-to-target hop uses Microsoft's own service-managed endpoints and needs nothing from you |
| Model A only: a deployment host | A VM in that VNet (+ Bastion), or VPN / ExpressRoute from where you work |
| Workstation | A working SQL client (see above), plus Azure CLI |
| Access | `db_owner` on that database, and a login that can be granted read on each target |

> **Why one database?** `jobs.job_executions` (the agent's history) ends up in
> the same database as `core.*` (the collected data). Azure SQL Database has no
> cross-database queries, so keeping them together is what lets the system
> answer *"this feed is stale — and here is the error that explains why"* in a
> single query. Split across two databases, that join is impossible and the
> dashboard can only show the symptom.
>
> The trade-off is a privilege one and it is handled explicitly in
> [section 4](#4-create-the-collector-identity): the account that writes
> collected data is **denied** write access to the `jobs` schema, so it can
> never alter what runs against your targets.

### Decide two things up front

**1. Which permission model.** This is the question your vendor cares about.

| | Option A — server role | Option B — contained user |
|---|---|---|
| Created in the monitored DB | **nothing** | one user |
| Created in `master` | 1 login + 2 role memberships | 1 login |
| Works if you have no `master` access | No | Yes |
| Recommended for vendor databases | **Yes** | Only if A is unavailable |

**2. Whether you will deploy the XE sessions.**

Skipping them costs you exactly two things — error events and deadlock graphs.
Everything else works. If in doubt, deploy without them, live with it for a
week, and add them later; it is a five-minute change either way.

### Sizing the repository

Roughly **250–400 MB per monitored database per month** at default retention,
dominated by `core.WaitStats`.

| Databases | First-month growth | Suggested tier |
|---|---|---|
| 1–10 | ~4 GB | S2 / GP_Gen5_2 |
| 10–50 | ~20 GB | S3 / GP_Gen5_4 |
| 50–200 | ~80 GB | GP_Gen5_8 |
| 200+ | ~300 GB+ | GP_Gen5_16, and shorten `Retention.StandardDays` |

---

## 2. Provision the Azure resources

### This deployment

Every example in this document uses these values. Change them here if you are
deploying somewhere else.

| | Value |
|---|---|
| Subscription | `<your-subscription>` |
| Resource group | `EnterpriseHealthDashboard` |
| Region | `centralus` |
| Logical server | `ehd-server` → `ehd-server.database.windows.net` |
| Database | `EnterpriseHealth` |
| Job agent | `ehd-agent` |
| Connectivity | **Elastic Jobs private endpoint** for collection; human/dashboard access depends on your tenant network policy |

> **Do not rely on region for public access.** A tenant policy can force
> `publicNetworkAccess = Disabled` and may revert a manual change later. Check
> the server after creation. Collection can run through the Elastic Jobs private
> endpoint; SSMS and dashboard generation need either temporary public access or
> your own private access path.

### Portal

**Resource group:** Portal → **Resource groups** → **+ Create** → name it, pick
the region, create.

**Logical server:** Portal → search **SQL servers** (*not* "SQL databases") →
**+ Create**

| Tab | Setting |
|---|---|
| Basics | Resource group, **Server name** (globally unique), Location |
| Basics → Authentication | **Use Microsoft Entra-only authentication** |
| | **Set admin** → yourself. No SQL admin password is required |
| Networking | **Allow Azure services and resources to access this server = No** |
| | **Add current client IP address = Yes** if public access is enabled |
| Review + create | |

> There is **no "Connectivity method" radio** when creating a *logical server* —
> that choice appears when you create a *database*. The server's Networking tab
> only offers the firewall toggles above. Public/private access is set
> afterwards under **Security → Networking** on the created server.

Leave **Allow Azure services** off for now. It creates the `0.0.0.0` rule that
admits every Azure subscription in the world. Section 2's *"Connect the agent to
your targets"* gives you the narrower alternative — but note that you must do
**one or the other** before any collection job can reach a target, including the
repository's own server.

### Or the CLI

```bash
RG=EnterpriseHealthDashboard
LOC=centralus
SRV=ehd-server
ADMIN=ehdadmin

az group create -n $RG -l $LOC

az sql server create -g $RG -n $SRV -l $LOC \
   -u $ADMIN -p '<strong password>'

# THE database - agent job database and repository in one.
# S1 is the documented minimum for a job database on the DTU model.
# Serverless with auto-pause is NOT supported: the agent keeps it from pausing.
az sql db create -g $RG -s $SRV -n EnterpriseHealth \
   --service-objective S2
```

### Gate 1 — which connectivity model are you actually on?

```bash
az sql server show -g EnterpriseHealthDashboard -n ehd-server \
   --query "publicNetworkAccess" -o tsv
```

Portal equivalent: server → **Security → Networking → Public network access**.

| Result | Path |
|---|---|
| `Enabled` / "Selected networks" | **Model B.** Nothing more to build — connect from SSMS and carry on at section 3 |
| `Disabled` | **Model A.** Add a private endpoint and a VNet-connected host — see below |

Also confirm on the **Overview** blade that *Microsoft Entra admin* is you.

### Model A — only if Gate 1 returned `Disabled`

Give yourself a private route in. If policy already disabled public access there
is nothing to undo; skip straight to the VNet and private endpoint.

```bash
VNET=vnet-sqlmon
SUBNET=snet-data

# a VNet for YOUR access. The job-agent-to-target hop does not use this.
az network vnet create -g $RG -n $VNET -l $LOC \
   --address-prefix 10.20.0.0/16 \
   --subnet-name $SUBNET --subnet-prefix 10.20.1.0/24

SRVID=$(az sql server show -g $RG -n $SRV --query id -o tsv)

az network private-endpoint create -g $RG -n pe-$SRV -l $LOC \
   --vnet-name $VNET --subnet $SUBNET \
   --private-connection-resource-id $SRVID \
   --group-id sqlServer \
   --connection-name pe-$SRV-conn

# private DNS so the FQDN resolves to the private IP inside the VNet
az network private-dns zone create -g $RG -n "privatelink.database.windows.net"
az network private-dns link vnet create -g $RG -n link-$VNET \
   -z "privatelink.database.windows.net" -v $VNET -e false
az network private-endpoint dns-zone-group create -g $RG \
   --endpoint-name pe-$SRV -n zg-$SRV \
   --private-dns-zone "privatelink.database.windows.net" --zone-name sql

# explicitly confirm the public endpoint is closed
az sql server update -g $RG -n $SRV --enable-public-network false
```

You now need a host inside `$VNET` to run the schema deployment from — a small
VM reached through Azure Bastion is the documented pattern, and VPN or
ExpressRoute work equally well. Everything from section 3 onward runs there.

> Default **Azure Cloud Shell will not work** against a private-only server:
> *"Commands that run inside the container can't access resources in a private
> virtual network."* Only a VNet-isolated Cloud Shell deployment can.
> The **Portal Query Editor** works only when your browser is itself inside the
> private network path.

### Model B — if Gate 1 returned `Enabled`

**This is the path this deployment is on.** Nothing further to build: the client
IP rule added during server creation is enough. Connect from SSMS and go to
section 3.

To add another workstation later:

```bash
az sql server firewall-rule create -g EnterpriseHealthDashboard -s ehd-server \
   -n AnotherMachine --start-ip-address <ip> --end-ip-address <ip>
```

Note there is deliberately **no `AllowAllWindowsAzureIps` (0.0.0.0) rule** here.
That rule admits connections from every Azure subscription, not just yours. The
elastic-jobs private endpoint in *"Connect the agent to your targets"* below is
the narrower replacement — but you need one of the two, and the IP rule you just
added covers only *your laptop*, not the job agent.

---

**Deploy the repository schema now, before creating the agent** (section 3).

The agent and the repository share this one database. That is supported, not a
workaround: the agent creates its own `jobs` and `jobs_internal` schemas, and
`cfg` / `stg` / `core` sit alongside them without conflict. Microsoft's "point
the agent at a clean database" line is *guidance aimed at avoiding surprises*,
not a product restriction — a job database is an ordinary Azure SQL Database
and may contain whatever else you put in it.

Deploying our schemas first also means the agent is added to a database whose
only contents are ours, which satisfies that guidance in spirit.

Then create the agent against that same database.

> **`az sql elastic-job` does not exist.** Azure CLI has no command group for
> Elastic Job Agents — not in `az sql`, and not in any extension. Use one of
> the two paths below.

**Option 1 — ARM REST via the Azure CLI** (no extra module needed):

```bash
SUB=$(az account show --query id -o tsv)
RG=EnterpriseHealthDashboard
SRV=ehd-server
DB=EnterpriseHealth
LOC=centralus

cat > agent.json <<EOF
{
  "location": "$LOC",
  "sku": { "name": "JA100", "capacity": 100 },
  "properties": {
    "databaseId": "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Sql/servers/$SRV/databases/$DB"
  }
}
EOF

az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Sql/servers/$SRV/jobAgents/ehd-agent?api-version=2023-05-01-preview" \
  --headers "Content-Type=application/json" \
  --body @agent.json
```

> On Windows, **always pass the body as `@file`**. Inline JSON gets mangled by
> `cmd.exe` quoting and fails with
> `InvalidRequestContent: Unexpected character encountered while parsing value`.

Poll until it is ready — creation takes several minutes:

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Sql/servers/$SRV/jobAgents/ehd-agent?api-version=2023-05-01-preview" \
  --query "properties.state" -o tsv
```

**Option 2 — Az PowerShell:**

```powershell
Install-Module Az.Sql -Scope CurrentUser
$db = Get-AzSqlDatabase -ResourceGroupName EnterpriseHealthDashboard -ServerName ehd-server -DatabaseName 'EnterpriseHealth'
New-AzSqlElasticJobAgent -Name 'ehd-agent' -DatabaseObject $db
```

> **The 1:1 is agent-to-database, not database-to-agent-only.** One job database
> hosts exactly one agent, and an existing agent cannot be repointed at a
> different database. That is the only constraint. It does **not** mean the job
> database must be reserved for the agent — this design deliberately puts the
> repository in the same database, which is fully supported.

### Connect the agent to your targets

Once the agent exists, give it a route to each monitored server. **Do not reach
for the `AllowAllWindowsAzureIps` firewall rule** — Microsoft's own guidance is
that it is unnecessary here:

> "Configuring a firewall rule with `New-AzSqlServerFirewallRule` is unnecessary
> when using elastic jobs private endpoint."
> — [Create an elastic job with PowerShell](https://learn.microsoft.com/en-us/azure/azure-sql/database/elastic-jobs-powershell-create?view=azuresql)

That rule opens the server to **every Azure subscription in the world**, not
just yours. The private endpoint is both simpler and narrower.

In the portal, on the **Elastic Job Agent**:

1. **Security → Private endpoints → Add a server and create private endpoint**
2. Pick the target logical server. Connection status goes to **Pending**.
3. On the **target SQL server** → *Networking → Private access* → **Approve**
   the pending request.

Repeat per target **logical server** — not per database. Microsoft operates
these endpoints for you; you do not supply a VNet, a subnet or DNS for this hop:

> "Each target server can be reached via a service-managed private endpoint,
> created and managed by Microsoft, and exclusively for use with elastic jobs...
> Once configured, all communication between the elastic job agent and the
> target server will occur through the private endpoint."

**Including the repository's own server.** This is the trap: even when the
agent, the job database and the repository are all on the *same* logical server,
the agent's connection to that server **as a target** still goes through the
firewall / private-endpoint path. Sharing a server buys you nothing here. If you
skip this step you get:

```
Failed to connect to the target database: Cannot open server 'ehd-server'
requested by the login. Client with IP address '20.x.x.x' is not allowed to
access the server.
```

…even though you can reach the same database from SSMS perfectly well. The IP in
that message is the agent's, not yours, and it is not stable — do not try to
allow-list it.

#### Gate — the agent must be able to reach its own server

Do this **before** adding any target group member. Either:

- **Private endpoint** (recommended): agent blade → *Security → Private
  endpoints* → add `ehd-server` → then approve it on `ehd-server` → *Networking
  → Private access*. Status must read **Approved**, not Pending.
- **or the firewall rule** (sandbox only). In `master` on the target server:
  ```sql
  EXEC sp_set_firewall_rule N'AllowAllWindowsAzureIps', '0.0.0.0', '0.0.0.0';
  ```
  Portal equivalent: *Networking → Public access →* **Allow Azure services and
  resources to access this server**. Understand what you are enabling: it admits
  every Azure subscription in the world, not just yours.

Allow up to five minutes for either change to take effect.

---

## 3. Deploy the repository schema

### First: where are you running this from?

The server is private-only, so settle this before anything else. It takes two
minutes and decides whether you need any extra infrastructure at all.

Open SSMS against `ehd-server.database.windows.net` from your workstation:

| Result | What it means | Do this |
|---|---|---|
| **Connects** | your network already resolves and routes to the private endpoint | run everything below from SSMS. **No VM, no container, nothing else to build** |
| **Error 47073** | you are resolving the public IP, or have no route | check `Resolve-DnsName ehd-server.database.windows.net` — `10.x` means routing, a public IP means DNS. Then use a host inside the VNet |

Creating a logical server costs nothing, so get to this test early rather than
planning infrastructure you may not need.

### The scripts, in order

Seven files, **in filename order**. The numbering *is* the execution order:
job health is `04` because the alert engine (`05`) reads `core.vw_JobHealth`.

| # | File | What it creates |
|---|---|---|
| 1 | `01-central\00-schemas-and-config.sql` | `cfg` / `stg` / `core` schemas, 34 settings, `cfg.Target`, `ProcessRun`, `FeedArrival` |
| 2 | `01-central\01-core-tables.sql` | the modelled tables |
| 3 | `01-central\02-normalize.sql` | `usp_Normalize`, `fn_StagingReady`, `usp_PurgeStaging` |
| 4 | `01-central\03-views.sql` | analysis views + fleet scorecard |
| 5 | `01-central\04-job-health.sql` | job-health views — **stubs at this point**, the `jobs` schema does not exist yet |
| 6 | `01-central\05-alerts.sql` | alert engine (reads `vw_JobHealth`) |
| 7 | `01-central\06-purge.sql` | retention + storage report |

**From SSMS:** open each file and execute it in order against the repository
database. SSMS sets `QUOTED_IDENTIFIER ON` by default, and every script sets it
explicitly anyway.

**From the command line:**

```powershell
cd 'C:\...\EnterpriseHealthDashboard'

"00-schemas-and-config","01-core-tables","02-normalize","03-views",
"04-job-health","05-alerts","06-purge" | ForEach-Object {
    sqlcmd -S ehd-server.database.windows.net -d EnterpriseHealth -G -b `
           -i "01-central\$_.sql"
    if ($LASTEXITCODE) { throw "FAILED on $_ - fix before continuing" }
}
```

**Or let the orchestrator do it** (same order, plus the verification query):

```powershell
.\deploy\Deploy-Enterprise.ps1 -Phase Central `
    -CentralServer   ehd-server.database.windows.net `
    -CentralDatabase EnterpriseHealth
```

> `-b` makes `sqlcmd` return a non-zero exit code on error. Without it a failed
> script looks identical to a successful one, and you will not notice until
> three files later when something references a table that was never created.

**Verify:**

```sql
SELECT Tables_   = (SELECT COUNT(*) FROM sys.tables     t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='core'),
       Views_    = (SELECT COUNT(*) FROM sys.views      v JOIN sys.schemas s ON s.schema_id=v.schema_id WHERE s.name='core'),
       Procs_    = (SELECT COUNT(*) FROM sys.procedures p JOIN sys.schemas s ON s.schema_id=p.schema_id WHERE s.name='core'),
       Settings_ = (SELECT COUNT(*) FROM cfg.Setting);
```

Expect **25 tables, 22 views, 8 procedures, 34 settings** (measured on a clean
deployment). Materially fewer settings means the `MERGE` did not complete —
re-run `00-schemas-and-config.sql`. Materially fewer views usually means a
script failed silently; re-run them with `-b` and watch for the first error.

---

## 4. Create the collector identity

`20-agent-setup.sql` creates the credential objects but **cannot invent a
password or grant anything**. Do this part by hand.

### Option A — server role (zero footprint)

Run in **`master` on each monitored server**:

```sql
CREATE LOGIN ehd_collector WITH PASSWORD = '<strong password>';
ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER ehd_collector;
ALTER SERVER ROLE ##MS_DefinitionReader##  ADD MEMBER ehd_collector;
```

Check the roles exist before you promise this to anyone:

```sql
SELECT name FROM sys.server_principals
WHERE type = 'R' AND name LIKE '##MS[_]%';
```

If they are absent, fall back to Option B.

### Option B — contained user

Run in **each monitored database**:

```sql
CREATE USER ehd_collector WITH PASSWORD = '<strong password>';
GRANT VIEW DATABASE STATE   TO ehd_collector;
GRANT VIEW DEFINITION       TO ehd_collector;
GRANT SELECT ON sys.dm_db_resource_stats TO ehd_collector;
```

### Database-scoped credentials — SQL authentication only

> ⚠️ **Not used in this deployment, and not the recommended path.** This system
> authenticates with the job agent's **user-assigned managed identity**, so there
> are no credentials, no master key and no passwords to rotate. Skip this block
> entirely unless you are on a server where Entra authentication is impossible.
>
> You **cannot mix** the two. Per Microsoft: *"for a single elastic job agent,
> you can't configure one target server to use database-scoped credentials and
> another to use Microsoft Entra ID authentication."*

Run in **the database** (same one):

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<key password>';

-- used to connect TO the monitored databases (read-only)
CREATE DATABASE SCOPED CREDENTIAL ehd_target_cred
  WITH IDENTITY = 'ehd_collector', SECRET = '<the password above>';

-- used to write staging results here, and to run the processing procedures
CREATE DATABASE SCOPED CREDENTIAL ehd_output_cred
  WITH IDENTITY = 'ehd_writer',    SECRET = '<writer password>';

-- the writer principal
CREATE USER ehd_writer WITH PASSWORD = '<writer password>';
```

If you take this path you must also add `@credential_name` and
`@output_credential_name` back to every `sp_add_jobstep` call in
`03-elasticjobs\21|22|23|24|25-*.sql`, and `@refresh_credential_name` to any
whole-server target group member. The shipped scripts omit all three.

### The privilege boundary — do not skip this

`ehd_writer` must be able to create the `stg.*` tables (the Job Agent does that
on first run) and to execute the processing procedures. The lazy way is
`db_owner`. **Do not.**

In a single-database design `db_owner` also grants control over the `jobs`
schema — meaning the account that writes monitoring data could rewrite
`jobs.jobsteps`, i.e. change the SQL that executes against your production and
vendor databases. For a system whose whole claim is *"we only ever SELECT on
your database"*, that quietly undermines the guarantee.

Grant only what is needed, then deny the rest:

```sql
GRANT CREATE TABLE TO ehd_writer;               -- agent creates stg.* on first run
GRANT ALTER   ON SCHEMA::stg  TO ehd_writer;    -- ...inside stg, nowhere else
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::stg  TO ehd_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::core TO ehd_writer;
GRANT SELECT  ON SCHEMA::cfg  TO ehd_writer;
GRANT EXECUTE ON SCHEMA::core TO ehd_writer;

-- EXECUTE on cfg, for the scalar settings readers cfg.fn_Int / cfg.fn_Dec.
-- SELECT on the schema does NOT cover scalar functions. Ownership chaining
-- usually hides this, but the normalizer builds its per-feed statements with
-- sp_executesql, and a chain does not carry into dynamic SQL - so the call is
-- permission-checked against the agent identity. Symptom: every collection job
-- succeeds and 01_Normalize fails, but ONLY when the agent runs it. The same
-- procedure works when a human admin runs it (admins already have EXECUTE),
-- which makes it look like a job-agent fault rather than a missing grant.
-- Read-only: these functions parse cfg.Setting and return int/decimal.
GRANT EXECUTE ON SCHEMA::cfg TO ehd_writer;

GRANT VIEW DEFINITION TO ehd_writer;            -- fn_StagingReady reads sys.columns

-- Write access to cfg.Target, and to NOTHING else in cfg.
-- EHD_Process_Daily step 03_SyncTargetRegistry updates LastSeenUtc and inserts
-- newly reporting databases, and core.usp_RecordArrival merges the same table on
-- every normalize pass. With SELECT alone the job step fails every day with
-- "The UPDATE permission was denied on the object 'Target' ... schema 'cfg'",
-- and the merge inside the normalizer fails too - so a database you just
-- onboarded sends data that never appears on the fleet scorecard.
-- Scoped to the object: SCHEMA::cfg would also hand the job write access to
-- cfg.Setting, which holds retention windows and alert thresholds.
GRANT INSERT, UPDATE ON OBJECT::cfg.Target TO ehd_writer;

-- Every form of WRITE against the job control plane is refused.
-- DENY beats GRANT and beats role membership, so this holds even if somebody
-- later adds ehd_writer to a broad role.
--
-- NOTE THE ABSENCE OF **CONTROL** ON [jobs], AND DO NOT ADD IT.
-- CONTROL implies every permission on the securable, so DENY ... CONTROL also
-- denies SELECT. That silently revokes the read access core.vw_JobHealth needs,
-- and you get "The SELECT permission was denied on the object 'job_executions'"
-- while normalization keeps working - which reads as an alerting bug for as long
-- as you care to look. Deny the specific write permissions instead.
DENY INSERT, UPDATE, DELETE, ALTER, EXECUTE ON SCHEMA::jobs          TO ehd_writer;

-- jobs_internal is different: nothing here needs to read it, so the catch-all
-- DENY is appropriate.
DENY INSERT, UPDATE, DELETE, ALTER, CONTROL  ON SCHEMA::jobs_internal TO ehd_writer;
```

Verify it took — `20-agent-setup.sql` runs this check for you, or run it directly.
Note that it checks **both halves**: that writes are denied, *and* that reads on
`[jobs]` are still possible. Asserting only "a DENY exists" passes happily for an
over-broad `DENY ... CONTROL` that has already broken the system:

```sql
SELECT  SchemaName   = s.name,
        WritesDenied = MAX(CASE WHEN p.state_desc = 'DENY'
                                 AND p.permission_name IN ('INSERT','UPDATE','DELETE',
                                                           'ALTER','EXECUTE','CONTROL')
                                THEN 1 ELSE 0 END),
        /* CONTROL and SELECT denials both block reads - CONTROL implies SELECT */
        ReadBlocked  = MAX(CASE WHEN p.state_desc = 'DENY'
                                 AND p.permission_name IN ('SELECT','CONTROL')
                                THEN 1 ELSE 0 END)
FROM    sys.database_permissions AS p
JOIN    sys.schemas AS s ON s.schema_id = p.major_id
WHERE   p.class = 3
  AND   p.grantee_principal_id = DATABASE_PRINCIPAL_ID('ehd_writer')
  AND   s.name IN ('jobs', 'jobs_internal')
GROUP BY s.name;
```

Expected: `jobs` → `WritesDenied = 1`, **`ReadBlocked = 0`**; `jobs_internal` →
`WritesDenied = 1` (read there is irrelevant). If `jobs` comes back with
`ReadBlocked = 1`, fix it with:

```sql
REVOKE CONTROL ON SCHEMA::jobs FROM ehd_writer;
```

### Entra-only estates (managed identity)

Everything above assumes SQL authentication is permitted. **If the server has
`azureADOnlyAuthentication = true`, none of it is legal** — `CREATE LOGIN ...
WITH PASSWORD`, `CREATE USER ... WITH PASSWORD` and `DATABASE SCOPED CREDENTIAL
... SECRET` are all rejected outright.

This is increasingly the default in regulated tenants, so check before you
plan. The replacement is a **user-assigned managed identity** on the job agent:

1. Create a UMI and attach it to the job agent at creation time (`identity` in
   the ARM body, or `-UserAssignedIdentityId` on `New-AzSqlElasticJobAgent`).

2. In **each target database**, create a contained user for the UMI and grant
   it read:

   ```sql
   CREATE USER [ehd-umi] FROM EXTERNAL PROVIDER;
   GRANT VIEW DATABASE STATE TO [ehd-umi];
   GRANT VIEW DEFINITION     TO [ehd-umi];
   ```

   Note this is a footprint in the target database — one user. The zero-footprint
   `##MS_ServerStateReader##` route needs a server-level principal, which for a
   UMI means adding it in `master` on the target's server.

3. In the **job database**, create the same user and give it the scoped grants
   and the `jobs`-schema DENY from the previous section.

4. In the job step definitions, **omit `@credential_name`** so the agent
   authenticates as its managed identity.

The job scripts in `03-elasticjobs\` **are already written for managed identity**
— no `@credential_name`, no `@output_credential_name`, no
`@refresh_credential_name` anywhere. Nothing to edit. If you ever add a step by
hand, leave those parameters off too: an agent cannot mix credential types.
After any edit, re-run the read-only contract test:

```powershell
.\tests\Test-EmbeddedCommands.ps1
```

---

## 5. Deploy the jobs

Six files, plus a re-run of `04-job-health.sql`. **No SQLCMD mode and no `-v`
switches are needed.** The server name is a plain T-SQL variable inside each
script:

```sql
DECLARE @OutServer nvarchar(256) = N'ehd-server.database.windows.net';
```

It appears **twice per file** (T-SQL variables do not survive a `GO`), already
set to `ehd-server.database.windows.net`. Each script then compares that literal
against `SERVERPROPERTY('ServerName')` and **uses the live connection if they
disagree**, printing a note — the repository is this database, so the output
server is by definition the server you are connected to. The *database* comes
from `DB_NAME()`. Together that makes it impossible to aim the output at the
wrong place; edit the literal only if you rename or move the server.

| # | File | What it creates |
|---|---|---|
| 1 | `03-elasticjobs\20-agent-setup.sql` | UMI grants + target groups |
| 2 | `03-elasticjobs\21-jobs-frequent.sql` | `EHD_Collect_Frequent`, 5 steps |
| 3 | `03-elasticjobs\22-jobs-standard.sql` | `EHD_Collect_Standard`, 7 steps |
| 4 | `03-elasticjobs\23-jobs-daily.sql` | `EHD_Collect_Daily`, 6 steps |
| 5 | `03-elasticjobs\24-jobs-process.sql` | `EHD_Process_Frequent` / `_Daily` |
| 6 | `03-elasticjobs\25-jobs-setup.sql` | `EHD_Setup_Targets` — **optional**, created **disabled**. The only job that writes to a target |
| 7 | `01-central\04-job-health.sql` | **re-run** — swaps the stub views for live ones |

**From SSMS:** open each file in order and press F5. Nothing else. (Always
Encrypted parameterization must still be off — see §12.)

> ⚠️ **Disable the collect jobs before REDEPLOYING step definitions.** Once a
> target group has members, `EHD_Collect_Frequent` (5 min) and
> `EHD_Collect_Standard` (30 min) fire on their own schedule and will race your
> redeploy — a job can run with the *old* command text seconds before you
> replace it, creating `stg.*` tables with the old shape. Those tables are then
> reused for every later run, so the stale shape persists silently.
>
> ```sql
> EXEC jobs.sp_update_job @job_name = N'EHD_Collect_Frequent', @enabled = 0;
> EXEC jobs.sp_update_job @job_name = N'EHD_Collect_Standard', @enabled = 0;
> EXEC jobs.sp_update_job @job_name = N'EHD_Collect_Daily',    @enabled = 0;
> ```
>
> Redeploy, then re-enable. If a collection query's output columns changed, also
> `DROP` the affected `stg.*` tables — the agent only creates a table when it is
> missing, and will happily insert into an existing one with the old shape.

**From the command line:**

```powershell
$SRV = 'ehd-server.database.windows.net'

"20-agent-setup","21-jobs-frequent","22-jobs-standard","23-jobs-daily","24-jobs-process","25-jobs-setup" |
  ForEach-Object {
    sqlcmd -S $SRV -d EnterpriseHealth -G -b -i "03-elasticjobs\$_.sql"
    if ($LASTEXITCODE) { throw "FAILED on $_" }
  }

# now that jobs.job_executions exists, make the job-health views real
sqlcmd -S $SRV -d EnterpriseHealth -G -b -i "01-central\04-job-health.sql"
```

**Or the orchestrator** (does all six, in order):

```powershell
.\deploy\Deploy-Enterprise.ps1 -Phase Agent `
    -CentralServer   ehd-server.database.windows.net `
    -CentralDatabase EnterpriseHealth
```

Creates:

| Job | Schedule | Steps | Runs against |
|---|---|---|---|
| `EHD_Collect_Frequent` | every 5 min | 5 | `EHD_AllTargets` |
| `EHD_Collect_Standard` | every 30 min | 7 | `EHD_AllTargets` |
| `EHD_Collect_Daily` | 03:00 UTC | 6 | `EHD_AllTargets` |
| `EHD_Process_Frequent` | every 5 min, **+2 min offset** | 2 | `EHD_Central` |
| `EHD_Process_Daily` | 03:15 UTC | 3 | `EHD_Central` |
| `EHD_Setup_Targets` | weekly (optional) | 0 until you add them | `EHD_AllTargets` |

The 2-minute offset on `EHD_Process_Frequent` stops it racing the collection it
is meant to consume. `EHD_Central` contains exactly one member: this database —
a job agent database is an ordinary Azure SQL Database and can be its own
target.

The phase also **re-runs `04-job-health.sql`**. On a first deployment those
views were created as empty stubs because `jobs.job_executions` did not exist
yet; re-running swaps in the live definitions. The script tells you which one
you got.

**Verify:**

```sql
SELECT j.job_name, j.enabled, j.schedule_interval_type, j.schedule_interval_count,
       Steps = (SELECT COUNT(*) FROM jobs.jobsteps s
                WHERE s.job_id = j.job_id AND s.job_version = j.job_version)
FROM   jobs.jobs j
WHERE  j.job_name LIKE 'EHD[_]%'
ORDER BY j.job_name;

-- and that job health is live, not stubbed
SELECT IsLive = CASE WHEN OBJECT_ID('jobs.job_executions') IS NULL THEN 0 ELSE 1 END;
```

---

## 6. Optional: target-side setup

**Skip this whole section if your compliance position forbids it.** Everything
below is the only part of the system that creates anything in a monitored
database.

```
02-targets\10-target-permissions.sql   grants only, no objects
02-targets\11-target-xe-sessions.sql   2 XE sessions, ring buffer only
02-targets\12-target-querystore.sql    ALTER DATABASE SET QUERY_STORE
```

Run them manually per database, or paste their contents into the two steps of
`EHD_Setup_Targets` so new databases are configured automatically. All three
are idempotent.

The XE sessions use a **ring buffer target only** — a file target would need a
`DATABASE SCOPED CREDENTIAL` inside the vendor database. Durability comes from
the Standard job harvesting the buffer every 30 minutes.

**To remove them completely**, the removal script at the bottom of
`11-target-xe-sessions.sql` returns the database to its original state.

---

## 7. Onboard your first database

Two steps, in this order.

**a) Register it** (the database) — drives the fleet scorecard. Use the stored
procedure and the **short** server name:

```sql
EXEC cfg.usp_RegisterTarget
     @ServerName    = N'sql-prod',      -- no .database.windows.net
     @DatabaseName  = N'AppDb',
     @Environment   = N'Production',
     @Owner         = N'payments-team@contoso.com',
     @Criticality   = N'High',
     @IsVendorOwned = 1;
```

**b) Add it to the collection group** (same database) — drives collection:

```sql
EXEC jobs.sp_add_target_group_member
     @target_group_name = 'EHD_AllTargets',
     @membership_type   = 'Include',
     @target_type       = 'SqlDatabase',
     @server_name       = 'sql-prod.database.windows.net',
     @database_name     = 'AppDb';
```

### Onboard a whole server, minus exceptions

```sql
-- No credential argument: the agent uses its managed identity. For a whole-server
-- member the identity must also exist as a LOGIN in that server's master, with
-- ##MS_DatabaseConnector##, ##MS_ServerStateReader## and ##MS_DefinitionReader##.
EXEC jobs.sp_add_target_group_member
     @target_group_name = N'EHD_AllTargets', @membership_type = N'Include',
     @target_type = N'SqlServer', @server_name = N'sql-prod.database.windows.net';

EXEC jobs.sp_add_target_group_member 'EHD_AllTargets', 'Exclude',
     'SqlDatabase', 'sql-prod.database.windows.net', 'ReportingCopy';
```

Server membership with managed identity needs the UMI to exist as a login in that server's `master`, plus `##MS_DatabaseConnector##`, `##MS_ServerStateReader##` and `##MS_DefinitionReader##`. Do not pass a refresh credential. New databases on that server are picked up automatically.

> Step (b) without (a) still works — `EHD_Process_Daily` auto-registers anything
> that reports but is missing from `cfg.Target`, with `Environment = Default`. Step (a)
> without (b) gives you a permanent `NO DATA` row, which is the correct and
> visible outcome.

---

## 8. The verification gate

**Do not skip this. Do not wait for the schedule.**

```sql
EXEC jobs.sp_start_job 'EHD_Collect_Frequent';
```

Wait ~60 seconds, then:

```sql
SELECT TOP 20 JobName, StepName, ServerName, DatabaseName,
       Lifecycle, LastMessage, StartTimeUtc
FROM   core.vw_JobExecution
ORDER BY StartTimeUtc DESC;
```

If that returns nothing at all, the view is still a stub — run
`01-central\04-job-health.sql` again now that the agent exists.

Then:

```powershell
sqlcmd -S ehd-server.database.windows.net -d EnterpriseHealth -G `
       -i tests\verify-staging-schema.sql
```

This checks the one assumption the build could not: the Job Agent creates the
`stg.*` tables itself and prepends bookkeeping columns whose names are
**agent-version-dependent**. If they differ from
`Staging.ServerColumn` / `Staging.DatabaseColumn`, normalization skips every
feed — cleanly, silently, by design.

Read the **CHECK 2** output, then the **SUMMARY** verdict:

| Verdict | Meaning |
|---|---|
| `HEALTHY` | Done. Move on. |
| `NOTHING HAS RUN` | Job never executed — check `core.vw_JobRunSummary` |
| `COLLECTION WORKS, NORMALIZATION DOES NOT` | Column-name mismatch — fix below |
| `FeedArrival is empty` | Redeploy `02-normalize.sql` |

**If the names differ:**

```sql
UPDATE cfg.Setting SET SettingValue = N'<actual server column>'
 WHERE SettingKey = 'Staging.ServerColumn';
UPDATE cfg.Setting SET SettingValue = N'<actual database column>'
 WHERE SettingKey = 'Staging.DatabaseColumn';

EXEC core.usp_Normalize;
```

Confirm each `UPDATE` reports **1 row affected**. Zero means you are editing a
key that does not exist.

Finally:

```sql
EXEC core.usp_Normalize;
EXEC core.usp_EvaluateAlerts;

SELECT * FROM core.vw_FleetScorecard;
SELECT * FROM core.vw_TargetStatus;
```

`usp_Normalize` returns `RowsNormalized`, `FeedsSkipped` and `FeedsFailed`.
**All three matter.** On a healthy estate with the XE sessions deployed,
`FeedsSkipped` and `FeedsFailed` should both be `0`:

* `FeedsSkipped > 0` — a `stg.*` table is missing a column the normalizer needs.
  Run `tests\verify-staging-schema.sql`. The usual culprit is the two XE feeds;
  see the `stg.XeErrors` / `stg.XeBlocking` row in §12.
* `FeedsFailed > 0` — a feed threw. The run is recorded as `PartialSuccess` and
  each failure gets its own row, so read them:

  ```sql
  SELECT StepName, ErrorNumber, ErrorMessage
  FROM   core.ProcessRun
  WHERE  StepName LIKE 'Normalize:%' AND Status = 'Failed'
  ORDER BY ProcessRunId DESC;
  ```

Then confirm the job-history join is live — this is what makes `vw_FeedDiagnosis`
and the `JOB_FAILING` alert work:

```sql
SELECT * FROM core.vw_FeedDiagnosis;
```

Every tier should read `Healthy` with a non-NULL `Attempts24h`. If `Attempts24h`
is NULL while the jobs are plainly running, the server-name join is broken —
redeploy `01-central\04-job-health.sql`.

---

## 9. Publish the dashboard

```powershell
.\04-dashboard\New-EnterpriseDashboard.ps1 `
    -CentralServer   ehd-server.database.windows.net `
    -CentralDatabase EnterpriseHealth `
    -OutputPath      .\04-dashboard\estate.html
```

One connection, no target is contacted. Use `-OutputPath` so the generated file does not overwrite the shipped `04-dashboard\dashboard.html` template. The output is a single self-contained file with no CDN dependency, safe to email or drop on a file share. The dashboard includes Environment and Health filters, a Local/UTC time toggle, and sortable detail tables.

> Run this from wherever the repository is reachable — the same place you ran
> section 3 from. The generator is the only part of the system that needs
> standing network access to the repository; collection, normalization, alerting
> and retention all run as Elastic Jobs **inside** the database and need nothing
> from you.

### Where to put the file

It contains CPU figures, query text, blocking detail and security drift from
production databases. **Do not put it on an anonymously-readable endpoint.**

| Option | Auth | Notes |
|---|---|---|
| SharePoint / Teams | Entra, already working | Simplest — it is one self-contained file. No new Azure resources |
| Azure Static Web Apps | Built-in Entra auth, free tier | Best dedicated option |
| Blob Storage static website | ⚠️ public by default | Only behind a private endpoint or SAS |

A neat end state: a **VNet-integrated Container Apps job** on a timer that
queries the repository over the private endpoint and writes the HTML straight
to blob storage. Serverless, nothing to patch, and it removes the last reason
to keep a VM alive.

### Scheduled refresh

Run this **wherever the repository is reachable from**. Under Model A that means
a host inside the VNet — the same VM you deployed the schema from is the obvious
choice. Under Model B, anywhere.

```powershell
$a = New-ScheduledTaskAction -Execute 'powershell.exe' `
     -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\...\New-EnterpriseDashboard.ps1" -CentralServer ehd-server.database.windows.net -CentralDatabase EnterpriseHealth -OutputPath \\fileshare\dashboards\estate.html'
$t = New-ScheduledTaskTrigger -Once -At (Get-Date) `
     -RepetitionInterval (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'EHD Dashboard' -Action $a -Trigger $t `
     -User 'DOMAIN\svc_ehd' -RunLevel Highest
```

Use `-AccessToken` or a managed identity for unattended runs. Writing the output
to a file share means readers never need database access at all — the HTML is
self-contained.

---

## 10. Day-2 operations

### Every morning — 30 seconds

```sql
SELECT * FROM core.vw_FleetSummary;

SELECT ServerName, DatabaseName, Severity, AlertCode, Message, AgeMinutes
FROM   core.vw_OpenAlerts
WHERE  Severity = 'Critical'
ORDER BY RaisedUtc;

-- anything the pipeline trapped overnight rather than failing on
SELECT StepName, Status, ErrorMessage, StartedUtc
FROM   core.ProcessRun
WHERE  Status IN ('Failed','PartialSuccess')
  AND  StartedUtc > DATEADD(HOUR, -24, SYSUTCDATETIME())
ORDER BY ProcessRunId DESC;
```

Or just open the dashboard — the Fleet tab is this query.

### Weekly

```sql
-- 1. is anything not reporting?
SELECT ServerName, DatabaseName, CollectionState, StaleTiers, LastAnyArrivalUtc
FROM   core.vw_TargetStatus
WHERE  CollectionState <> 'OK';

-- 2. capacity walls inside a quarter
SELECT ServerName, DatabaseName, PctUsed, GrowthMBPerDay,
       DaysUntilFull, Verdict, Confidence
FROM   core.vw_CapacityForecast
WHERE  DaysUntilFull IS NOT NULL AND DaysUntilFull <= 90
ORDER BY DaysUntilFull;

-- 3. repository size
EXEC core.usp_StorageReport;

-- 4. did the processing jobs actually run?
SELECT TOP 30 StepName, StartedUtc, CompletedUtc, Status, RowsAffected, ErrorMessage
FROM   core.ProcessRun
ORDER BY ProcessRunId DESC;
```

Anything in `core.ProcessRun` with `Status` of `Failed` or `PartialSuccess`
deserves a look — that table is the system's own audit trail.

### Monthly

```sql
-- security drift across the whole estate
SELECT * FROM core.vw_SecurityDrift ORDER BY Severity, DetectedDate DESC;

-- index advisories worth acting on
SELECT TOP 40 * FROM core.vw_MissingIndexTop  ORDER BY ImpactScore DESC;
SELECT TOP 40 * FROM core.vw_UnusedIndexes    WHERE Verdict LIKE 'DROP%' ORDER BY SizeMB DESC;
SELECT TOP 40 * FROM core.vw_FragmentationWork ORDER BY AvgFragmentationPct DESC;
```

The last three generate exact DDL in a column. **Nothing is ever executed
automatically** — this system does not write to a target, including for
maintenance. Copy the statement, review it, run it yourself.

Also verify the config contract still holds after any edit:

```powershell
.\tests\Test-SettingKeys.ps1
.\tests\Test-EmbeddedCommands.ps1
```

---

## 11. Tuning

All thresholds live in `cfg.Setting` and take effect on the next evaluation —
no redeploy, no restart.

```sql
-- see everything
SELECT SettingKey, SettingValue, Description
FROM   cfg.Setting ORDER BY SettingKey;

-- change one
UPDATE cfg.Setting
   SET SettingValue = N'85', ModifiedUtc = SYSUTCDATETIME()
 WHERE SettingKey = 'Alert.CpuWarnPct';
```

> **Always confirm `1 row affected`.** A key that does not exist updates nothing
> and reports success. `tests\Test-SettingKeys.ps1` guarantees every key the
> code reads is defined — run it if you are ever unsure.

### Common adjustments

| Symptom | Change |
|---|---|
| CPU alerts too noisy | Raise `Alert.CpuWarnPct` (default 75) |
| Blocking alerts on a batch system | Raise `Alert.BlockingSeconds` (default 30) |
| Repository growing too fast | Lower `Retention.StandardDays` (default 35) — biggest lever |
| Stale alerts during maintenance | Raise `Stale.FrequentMinutes` (default 20) |
| Capacity warnings too late | Raise `Alert.CapacityWarnDays` (default 30) |
| Too many fragmentation advisories | Raise `Alert.FragmentationPct` (default 30) |

### Silencing one database

```sql
UPDATE cfg.Target SET IsEnabled = 0
WHERE ServerName = N'sql-dev.database.windows.net' AND DatabaseName = N'Sandbox';
```

Collection continues (the job group is separate) but alerts stop and the
scorecard marks it `DISABLED`. To stop collection too, remove it from
`EHD_AllTargets`.

### Changing what is collected

Collection queries live **inside Elastic Job step definitions**, which cannot
read `cfg.Setting`. To change a `TOP (n)` or a filter, edit
`03-elasticjobs\21|22|23-jobs-*.sql`, re-run that file against the database, then **always**:

```powershell
.\tests\Test-EmbeddedCommands.ps1
```

That test is what stands between a typo and a write against a vendor database.

---

## 12. Troubleshooting

### Decision tree: the dashboard is empty

**Start here — one query now answers most of this**, because job history and
feed freshness live in the same database:

```sql
SELECT * FROM core.vw_FeedDiagnosis ORDER BY Diagnosis;
```

The `Diagnosis` column says what is wrong *and why*. If it is not conclusive:

```
Does cfg.Target have enabled rows?
├─ No  -> register targets (section 7a)
└─ Yes -> Do stg.* tables exist?
          ├─ No  -> the collection job has never succeeded
          │         SELECT * FROM core.vw_JobRunSummary ORDER BY Failures24h DESC
          │         ├─ "Login failed"        -> credential / permission (section 4)
          │         ├─ "not able to connect" -> no elastic-jobs private endpoint to
          │         │                            that target server, or it is not approved
│         └─ no rows at all        -> job disabled, or group is empty
          └─ Yes -> Do core.* tables have rows?
                    ├─ No  -> NORMALIZATION. Run tests\verify-staging-schema.sql.
                    │         Almost always the Staging.*Column mismatch.
                    └─ Yes -> regenerate the dashboard; check the -CentralDatabase
                              you passed is the one the jobs write to.
```

### Quick reference

| Symptom | Likely cause | Fix |
|---|---|---|
| **`Failed to connect to the target database: Object reference not set to an instance of an object.`** | the target is a **serverless database that was auto-paused**. The connection attempt triggers a resume, but the agent surfaces the race as a null-reference exception rather than anything meaningful | nothing to fix — the attempt itself wakes the database. Confirm with `az sql db show ... --query status` (expect `Online`, with a fresh `resumedDate`) and re-run the job. Note that once a serverless database is being polled it can **never auto-pause again**, which is a real and ongoing cost |
| **`Login failed for user '<token-identified principal>'`** | ① SSMS is still pointed at a database that does not exist on *this* server — a default database carried over from the previous connection. Azure SQL reports a missing database under Entra auth as a **login** failure, not "cannot open database", which is thoroughly misleading. ② Or the token really is for another account/tenant | Options → **Connect to database** → set it to `master` (or a database that exists there) and reconnect. Only if that is already correct, check the account: compare `SUSER_SNAME()` against `az sql server ad-admin list` |
| **`The SELECT permission was denied on the object 'job_executions'`, and `EvaluateAlerts` fails while `Normalize` succeeds** | the agent identity can write results but cannot READ job history. `core.vw_JobHealth` reads `jobs.job_executions`, and ownership chaining does not cross schemas owned by different principals | `ALTER ROLE jobs_reader ADD MEMBER [<your-umi>];` in the job database. The `DENY` on writes still applies |
| **Several feeds missing, and one earlier step in the same job failed** | **a failed step ABORTS the remaining steps in that job.** Steps 4-7 never run if step 3 fails, so their `stg.*` tables never appear — and it looks like four separate problems instead of one | fix the *first* failing step and re-run. Order the diagnosis by `step_id`, not by which table is missing |
| **Some `stg.*` tables have the new columns, others don't, after a redeploy** | an enabled collect job fired on its schedule *during* the redeploy and used the old command text | disable the collect jobs, `DROP` the stale `stg.*` tables, redeploy, re-enable. See the warning in §5 |
| **A redeploy appears to do nothing — `LEN(js.command)` is unchanged** | SSMS does not reload an open file when it changes on disk; F5 runs the stale editor buffer | close the tab (Ctrl+F4), reopen from disk, then verify with `SELECT step_name, LEN(command) FROM jobs.jobsteps` before running the job |
| **`Invalid object name 'sys.dm_...'` despite the reference sitting inside `BEGIN TRY`** | binding errors are raised at COMPILE time, before the `TRY` block is entered — `TRY/CATCH` cannot catch them | guard with `OBJECT_ID(...) IS NOT NULL` and defer the bind through `sp_executesql`, so the failure moves to run time where it *is* catchable. See the `Space` step in `22-jobs-standard.sql` |
| **Job says `Succeeded` but `stg.*` tables never appear, and `target_database_name` is NULL on every execution row** | **the target group is empty** — the job ran zero times and reported success | `SELECT * FROM jobs.target_group_members` — add the member, then re-run |
| **`Cannot open server '<srv>' requested by the login. Client with IP address '20.x.x.x' is not allowed`** | the job agent's own IP is blocked. Your client-IP firewall rule covers your laptop, not the agent. **Applies even when the agent and target share one logical server** | elastic-jobs private endpoint (approve it on the target server), or `EXEC sp_set_firewall_rule N'AllowAllWindowsAzureIps','0.0.0.0','0.0.0.0'` in `master`. Do not allow-list the agent IP — it is not stable |
| **`EHD_Process_Frequent` step `01_Normalize` fails, but ONLY when the agent runs it — `EXEC core.usp_Normalize` works fine when you run it yourself**, and every collection job succeeds | the agent identity has `SELECT` on `SCHEMA::cfg` but not `EXECUTE`, so it cannot call the scalar settings readers `cfg.fn_Int` / `cfg.fn_Dec`. Ownership chaining normally masks this, but the normalizer builds its per-feed statements with `sp_executesql` and a chain does not carry into dynamic SQL — so the call is checked against the caller. It works for you because an admin already has `EXECUTE` | `GRANT EXECUTE ON SCHEMA::cfg TO [<your-umi>];` — read-only, these functions only parse `cfg.Setting` |
| `Invalid object name 'stg.X'` | that step has never run | start the owning job manually |
| **`EHD_Process_Daily` step `03_SyncTargetRegistry` fails daily with `The UPDATE permission was denied on the object 'Target' ... schema 'cfg'`** — and newly onboarded databases never appear on the scorecard | the agent identity was granted `SELECT` on `SCHEMA::cfg` only, but that step (and the target merge inside `core.usp_RecordArrival`) writes to `cfg.Target`. The merge in the normalizer fails too, silently | `GRANT INSERT, UPDATE ON OBJECT::cfg.Target TO [<your-umi>];` in the job database. Object-scoped on purpose — do **not** widen to `SCHEMA::cfg`, which would also expose `cfg.Setting` |
| **`core.vw_FeedDiagnosis` reports `Data arrived earlier but no job has run in 24 h` while `core.vw_JobHealth` clearly shows successful runs**, and the `JOB_FAILING` alert never fires | job history records the **fully qualified** `target_server_name`, but `cfg.Target` and `core.FeedArrival` key on `@@SERVERNAME`, which is the **short** name. Every join between them matched nothing | redeploy `01-central\04-job-health.sql` — `core.vw_JobExecution` now normalizes `ServerName` to the short form and keeps the full name as `TargetServerFqdn` |
| **`Violation of PRIMARY KEY constraint 'PK_core_...'` during `Normalize`, often several feeds at once** | two normalize passes overlapped. `01_Normalize` is step 1 of *both* `EHD_Process_Frequent` (5 min) and `EHD_Process_Daily` (24 h), so their schedules collide once a day; both evaluate the anti-join before either inserts | redeploy `01-central\02-normalize.sql` — `core.usp_Normalize` now takes an application lock and a second caller records `Skipped` instead of racing |
| **`FeedsSkipped` is never zero, and `core.ErrorEvent` / `core.Deadlock` stay empty forever** | `stg.XeErrors` and `stg.XeBlocking` were created without `ServerName` / `DatabaseName`, because the collection query's empty-ring-buffer branch returned a narrower column list than its populated branch — and the agent types an output table from the first result set it sees, then never reshapes it | redeploy `03-elasticjobs\22-jobs-standard.sql`, then `DROP TABLE stg.XeErrors; DROP TABLE stg.XeBlocking;` and re-run `EHD_Collect_Standard` so the agent recreates them |
| One database `NO DATA`, others fine | not in the target group, or per-DB permission | check group membership and that the agent identity has `VIEW DATABASE STATE` |
| Every target fails with "not able to connect" | elastic-jobs private endpoint missing or still Pending | agent blade -> Security -> Private endpoints; approve on the target server |
| `Connection was denied... Deny Public Network Access` (47073) | you are connecting from outside the private network path | run from a VNet-connected host (Model A), not your workstation |
| All databases stale at once | the Elastic Job Agent is stopped or the database is paused | check the agent in the portal |
| Alerts never clear | `EHD_Process_Frequent` step 02 not running | `SELECT * FROM core.ProcessRun WHERE StepName='EvaluateAlerts'` |
| Alerts fire repeatedly for the same issue | expected — one row stays open and updates | check `RaisedUtc`, not row count |
| Tuning a setting has no effect | key name does not exist | `.\tests\Test-SettingKeys.ps1` |
| `CREATE INDEX failed ... 'QUOTED_IDENTIFIER'` | deploying with `sqlcmd.exe`, which defaults it OFF | every shipped script now sets it explicitly; if you wrote your own, add `SET QUOTED_IDENTIFIER ON;` |
| `Incorrect syntax near the keyword 'OR'` on a `CREATE OR ALTER`, plus `sp_describe_parameter_encryption` errors | **SSMS Always Encrypted parameterization** — see below | Query Options → Execution → Advanced → uncheck **Enable Parameterization for Always Encrypted** |
| `Invalid object name` cascading through later scripts | an earlier script aborted, so its tables were never created | fix the first error and redeploy in order — do not skip ahead |
| Repository near MAXSIZE | retention not running | `EXEC core.usp_Purge @DryRun = 1` |
| `usp_Purge` hits the batch guard | first purge after a retention change | expected; it resumes the next night |
| Capacity says "No wall within 10 years" | growth is flat | correct, not a bug |
| Dashboard shows old data | generator ran against a stale repository | check `meta.generatedUtc` in the footer |

### SSMS Always Encrypted parameterization breaks the DDL

If your SSMS has Always Encrypted enabled — common if you have done column
master key or `Set-SqlColumnEncryption` work — it silently **rewrites the
scripts before sending them**, and the resulting errors point nowhere near the
real cause.

What you see:

```
Msg 156, Level 15 — Incorrect syntax near the keyword 'OR'.
Msg 111, Level 15 — 'CREATE/ALTER PROCEDURE' must be the first statement in a query batch.
Msg 8180 — Procedure sp_describe_parameter_encryption ... Statement(s) could not be prepared.
Msg 206  — Operand type clash: datetime2 is incompatible with int
```

What actually happened — SSMS turned the literals in `DECLARE` statements into
parameters so it could ask the server about their encryption metadata:

```sql
-- what is in the file
DECLARE @rows bigint = 0, @total bigint = 0, @skipped int = 0;

-- what SSMS actually sent
DECLARE @rows bigint = @p2c69b77db..., @total bigint = @p1ceb21a8e..., @skipped int = @p6c2eb955...;
```

`sp_describe_parameter_encryption` cannot do this for DDL, so the batch fails.
The `datetime2 is incompatible with int` error is the same cause: a parameterized
`@Hours` loses its type inside `DATEADD(HOUR, -@Hours, SYSUTCDATETIME())`.

**Fix:** Query → **Query Options → Execution → Advanced** → uncheck
**Enable Parameterization for Always Encrypted**. Reconnect, re-run.

If it persists it is set on the connection: **Connect → Options → Always
Encrypted** → uncheck **Enable Always Encrypted**.

> **Reported line numbers are useless here.** SSMS parses the *rewritten* batch,
> so the line it reports refers to text you never wrote. Do not go hunting at
> that line in your file — it sent us chasing a non-existent stale-file problem.
> `sp_describe_parameter_encryption` appearing anywhere in the output is the
> real signal.

Neither `sqlcmd` nor `deploy\Invoke-EhdSql.py` does this, so if you are unsure
whether a failure is real, re-run the same file through one of those. If it
succeeds there, the script is fine and the problem is your SSMS session.

### Useful diagnostics

```sql
-- THE one to know. Feed freshness joined to the job outcome that explains it.
SELECT * FROM core.vw_FeedDiagnosis ORDER BY Diagnosis;

-- agent-wide: which job step is failing, and with what message
SELECT * FROM core.vw_JobRunSummary ORDER BY Failures24h DESC, FailurePct DESC;

-- raw job history, same database as core.*
SELECT TOP 50 JobName, StepName, ServerName, DatabaseName, Lifecycle,
       StartTimeUtc, DurationSec, Attempts, LastMessage
FROM   core.vw_JobExecution ORDER BY StartTimeUtc DESC;

-- our own processing history
SELECT TOP 50 StepName, StartedUtc, CompletedUtc, DurationMs,
       Status, RowsAffected, ErrorMessage
FROM   core.ProcessRun ORDER BY ProcessRunId DESC;

-- per-feed freshness, the ground truth for staleness
SELECT ServerName, DatabaseName, FeedName, Tier, LastArrivalUtc, LastRowCount,
       AgeMin = DATEDIFF(MINUTE, LastArrivalUtc, SYSUTCDATETIME())
FROM   core.FeedArrival ORDER BY LastArrivalUtc;
```

---

## 13. Incident runbooks

### A database stopped reporting

1. `SELECT * FROM core.vw_FeedDiagnosis WHERE DatabaseName = '<db>';` — the
   `Diagnosis` column usually names the cause outright, including the job's
   own error text.
2. If **all** tiers: connectivity or credential. `LastError` will say which.
3. If **one** tier: that job. Start it manually and read `last_message`.
4. If the database was **dropped or renamed**, remove it:
   ```sql
   UPDATE cfg.Target SET IsEnabled = 0 WHERE DatabaseName = N'<db>';
   ```
   then remove it from `EHD_AllTargets`.

Treat the frozen numbers as invalid until it reports again — that is precisely
why `COLLECTION_STALE` is evaluated before every resource rule.

### CPU critical on a production database

```sql
-- what is burning it
SELECT TOP 20 * FROM core.vw_TopQueries
WHERE ServerName = '<srv>' AND DatabaseName = '<db>' ORDER BY TotalCpuSec DESC;

-- did something regress
SELECT * FROM core.vw_QueryRegression
WHERE ServerName = '<srv>' AND DatabaseName = '<db>' ORDER BY CpuRegressionX DESC;

-- what is it waiting on
SELECT TOP 10 * FROM core.vw_TopWaits
WHERE ServerName = '<srv>' AND DatabaseName = '<db>' ORDER BY ResourceWaitSec DESC;
```

A high `CpuRegressionX` with `PlanCountChange > 0` is a plan regression —
usually parameter sniffing after a statistics update.

### Workers critical

Worker exhaustion is nearly always **blocking**, not load. At 100% the database
refuses logins with error 10928 and looks completely down to the application.

```sql
SELECT * FROM core.vw_BlockingSummary
WHERE ServerName = '<srv>' AND DatabaseName = '<db>' ORDER BY MaxWaitSec DESC;
```

A head blocker with `BlockerStatus = 'sleeping'` means an application opened a
transaction and never committed. Look at `BlockerProgram` and `BlockerHost`.

### Storage critical

```sql
SELECT * FROM core.vw_CapacityForecast WHERE DatabaseName = '<db>';

SELECT TOP 20 SchemaName, TableName, TotalMB, DataMB, IndexMB
FROM   core.TableSpace
WHERE  DatabaseName = '<db>'
  AND  SnapshotDate = (SELECT MAX(SnapshotDate) FROM core.TableSpace WHERE DatabaseName = '<db>')
ORDER BY TotalMB DESC;
```

At 100% every `INSERT` fails with error 40544. Raise `MAXSIZE` or scale the
tier — this is not a maintenance-window problem.

### The repository itself is filling up

```sql
EXEC core.usp_StorageReport;
EXEC core.usp_Purge @DryRun = 1;
```

`core.WaitStats` will be at the top. Then:

```sql
UPDATE cfg.Setting SET SettingValue = N'14' WHERE SettingKey = 'Retention.StandardDays';
EXEC core.usp_Purge @DryRun = 0;
```

The first purge after a large retention cut may hit the 1000-batch guard and
stop cleanly. That is intended — run it again, or let the nightly job continue.

---

## 14. Upgrade, rollback, offboard

### Upgrading

Every script is idempotent. `CREATE OR ALTER` for code, `IF NOT EXISTS` for
tables, `MERGE` for settings — **your tuned values are never overwritten**.

```powershell
.\deploy\Deploy-Enterprise.ps1 -Phase Central `
    -CentralServer <srv> -CentralDatabase <db>
.\tests\Test-SettingKeys.ps1
```

Always re-run the tests after editing job files.

### Rolling back one script

Views and procedures are stateless — redeploy the previous version of the file.
Table changes are additive; no destructive migrations are shipped.

### Removing one database from monitoring

```sql
-- 1. stop collecting (same database)
EXEC jobs.sp_delete_target_group_member ...   -- or add an Exclude member

-- 2. stop alerting (the database)
UPDATE cfg.Target SET IsEnabled = 0
WHERE ServerName = N'<srv>' AND DatabaseName = N'<db>';
```

History is retained until normal retention ages it out. To delete immediately,
delete from the `core.*` tables filtered on `(ServerName, DatabaseName)`.

### Removing the system from a target completely

Only relevant if you deployed section 6.

1. Run the removal block at the bottom of `02-targets\11-target-xe-sessions.sql`
   — drops both XE sessions.
2. If you used Option B, `DROP USER ehd_collector;` in the database.
3. If you used Option A, `DROP LOGIN ehd_collector;` in `master`.
4. Query Store: leave it. It is a first-party feature and disabling it loses
   history the database owner may want.

The database is then byte-for-byte as it was.

### Decommissioning entirely

Drop the Elastic Job Agent, drop the database, drop the logins. Nothing else exists.

---

## 15. Reference

### Objects

| Name | Type | Purpose |
|---|---|---|
| `core.usp_Normalize` | proc | `stg.*` → `core.*`, 18 feeds, each error-trapped. Serialized by an application lock; a second concurrent caller records `Skipped` |
| `core.usp_LogFeedFailure` | proc | Writes a failed feed to `core.ProcessRun` as `Normalize:<Feed>` so a trapped error cannot pass as success |
| `core.usp_EvaluateAlerts` | proc | Runs every rule for every enabled target |
| `core.usp_RaiseAlert` | proc | The only way an alert is created; de-duplicates |
| `core.usp_ResolveAlerts` | proc | Closes alerts that stopped firing |
| `core.usp_Purge` | proc | Retention, batched. `@DryRun = 1` to preview |
| `core.usp_PurgeStaging` | proc | Trims `stg.*` past `Retention.StagingHours` |
| `core.usp_StorageReport` | proc | What is consuming the repository |
| `core.fn_StagingReady` | function | Guard: table + required columns present |
| `core.vw_FleetScorecard` | view | One row per database — the payoff of going central |
| `core.vw_FleetSummary` | view | One row for the whole estate |
| `core.vw_TargetStatus` | view | Registry joined to arrival — staleness truth |
| `core.vw_FeedDiagnosis` | view | **Freshness joined to the job error that explains it** |
| `core.vw_JobHealth` | view | Per database + tier job outcomes, 24 h |
| `core.vw_JobExecution` | view | Raw step executions from `jobs.job_executions` |
| `core.vw_JobRunSummary` | view | Agent-wide job health |
| `core.vw_OpenAlerts` | view | Unresolved alerts with age |
| `core.vw_TopWaits` | view | Waits with plain-English interpretation |
| `core.vw_TopQueries` | view | Plan-cache deltas |
| `core.vw_QueryRegression` | view | Last 6 h vs the preceding 7 days |
| `core.vw_BlockingSummary` | view | Chains with the head blocker resolved |
| `core.vw_CapacityForecast` | view | Linear projection, clamped to 10 years |
| `core.vw_SecurityDrift` | view | Diff of the two most recent snapshots |
| `core.vw_IoLatency` | view | Per-file read/write latency |
| `core.vw_MissingIndexTop` / `vw_UnusedIndexes` / `vw_FragmentationWork` | views | Advisories with generated DDL |
| `core.ProcessRun` | table | The system's own audit trail |
| `core.FeedArrival` | table | Last arrival per feed per database |
| `cfg.Target` | table | Registry — drives the scorecard |
| `cfg.Setting` | table | All tuning |

### Alert codes

| Code | Severity | Fires when |
|---|---|---|
| `COLLECTION_NEVER` | Critical | Registered but no data has ever arrived |
| `COLLECTION_STALE` | Critical | Frequent tier stopped |
| `COLLECTION_PARTIAL` | Warning | A slower tier stopped |
| `CPU_CRITICAL` / `CPU_HIGH` | Critical / Warning | 15-min average CPU |
| `WORKERS_CRITICAL` / `WORKERS_HIGH` | Critical / Warning | Worker thread usage |
| `SESSIONS_HIGH` | Warning | Session count vs tier limit |
| `DATA_IO_HIGH`, `LOG_WRITE_HIGH`, `MEMORY_HIGH` | Warning | Resource limits |
| `SPACE_CRITICAL` / `SPACE_HIGH` | Critical / Warning | % of MAXSIZE |
| `CAPACITY_CRITICAL` / `CAPACITY_WARNING` | Critical / Warning | Projected days until full |
| `LOG_SPACE_HIGH`, `TEMPDB_HIGH` | Warning | Log / TempDB usage |
| `LONG_TRANSACTION` | Warning | Oldest open transaction |
| `BLOCKING_CRITICAL` / `BLOCKING` | Critical / Warning | Longest block in 15 min |
| `DEADLOCKS` | Warning | Deadlocks in 24 h |
| `ERROR_BURST` | Critical | Severity 17+ errors per hour |
| `QUERY_REGRESSION` | Warning | CPU vs 7-day baseline |
| `FRAGMENTATION` | Info | Indexes over threshold |
| `SECURITY_PRIVILEGE` | Critical | Principal gained a privileged role |
| `SECURITY_DRIFT` | Warning | Principal or role membership changed |
| `TIER_CHANGED` | Info | Service objective changed in 24 h |
| `XE_UNHEALTHY` | Warning | XE session stopped or dropping events |
| `JOB_FAILING` | Critical | Collection job failure rate over `Alert.JobFailurePct` |

### Tests

| Script | Needs a database? | Run it when |
|---|---|---|
| `tests\Test-SettingKeys.ps1` | No | After editing any `cfg.Setting` key or a threshold |
| `tests\Test-CentralPipeline.sql` | A scratch DB | **After any change to the alert engine or the views.** Injects a synthetic estate and asserts alerts fire, de-duplicate and auto-resolve |
| `tests\Test-EmbeddedCommands.ps1` | No | **After any edit to `21`/`22`/`23-jobs-*.sql`** |
| `tests\verify-staging-schema.sql` | Yes | Once after the first collection; then on any upgrade |

### Naming

| | Value |
|---|---|
| Collection jobs | `EHD_Collect_Frequent` / `_Standard` / `_Daily` |
| Processing jobs | `EHD_Process_Frequent` / `_Daily` |
| Optional setup job | `EHD_Setup_Targets` |
| Target groups | `EHD_AllTargets`, `EHD_Prod`, `EHD_Central` |
| Identity | `ehd-agent-umi` — the agent's user-assigned managed identity. No credentials, no passwords |
| Grants (job database) | `jobs_reader` role + scoped grants on `stg`/`core`/`cfg`; writes to `jobs` DENIED |
| Grants (target servers) | `##MS_DatabaseConnector##`, `##MS_ServerStateReader##`, `##MS_DefinitionReader##` in `master` — zero footprint in the target databases |
| XE sessions | `ehd_errors`, `ehd_blocking` |
| Schemas | `cfg` (config), `stg` (landing), `core` (modelled), `jobs` (the agent's, do not touch) |
