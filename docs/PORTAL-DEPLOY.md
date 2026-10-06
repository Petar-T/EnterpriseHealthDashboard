# Deploy the Enterprise Health Dashboard — Portal walkthrough

A step-by-step build using the Azure Portal, verified end to end on
2026-10-06. Every value you must change is listed once in §0 and referenced as
`<PLACEHOLDER>` throughout.

**Time:** ~45 minutes, of which ~10 is waiting for the job agent.

> **Portal does the Azure resources; SSMS does the SQL.** Steps 1–8 are Portal
> only. Steps 9–13 deploy the schema and jobs, which the Portal's Query Editor
> cannot do — the scripts use `GO` batch separators and `02-normalize.sql` alone
> is 53 KB. Use SSMS or Azure Data Studio for those.

---

## 0. Variables — set these once

Write your values in the right-hand column and use them consistently. Every
later step refers to these names.

| Placeholder | What it is | Default used here | Constraints |
|---|---|---|---|
| `<SUBSCRIPTION>` | Azure subscription | *your own* | You need **Owner** or **Contributor** |
| `<RESOURCE-GROUP>` | New resource group | `EnterpriseHealthDashboard` | Any valid name |
| `<REGION>` | Azure region | `Central US` | Use one region for every resource below |
| `<SERVER>` | Logical SQL server | `ehd-server-01` | **Globally unique across all of Azure.** Lowercase, digits, hyphens |
| `<DATABASE>` | Repository database | `EnterpriseHealth` | Any valid name |
| `<AGENT>` | Elastic Job Agent | `ehd-agent` | Unique within the server |
| `<UMI>` | Managed identity | `ehd-agent-umi` | Unique within the resource group |
| `<YOUR-IP>` | Your workstation's public IP | *filled in by the Portal* | Changes if you move networks or VPN |

The defaults are the values used throughout this document, so following it
unchanged — apart from `<SERVER>` — works. Every code block below uses them
literally, which means the only mandatory edit is the server name.

> **`<SERVER>` must be globally unique.** Logical server names share a single
> global DNS namespace, so a plain name like `ehd-server` is very likely already
> taken by someone else's subscription. The Portal only tells you at validation
> time. Pick something distinctive; if creation fails with *"name already
> exists"*, change it here and keep the rest of the walkthrough consistent.

### The repository is also a monitored database

By design, the first database this system monitors is its own repository. That
gives you a working estate of one before any production database is involved.
`<DATABASE>` therefore appears both as "where data is stored" and "what is being
watched". That is intentional, not a mistake in the steps.

---

## 1. Resource group

**Portal → Resource groups → + Create**

| Field | Value |
|---|---|
| Subscription | `<SUBSCRIPTION>` |
| Resource group | `<RESOURCE-GROUP>` |
| Region | `<REGION>` |

**Review + create → Create.**

---

## 2. Logical SQL server

**Portal → search `SQL servers`** — *not* "SQL databases" — **→ + Create**

| Tab | Field | Value |
|---|---|---|
| Basics | Resource group | `<RESOURCE-GROUP>` |
| | Server name | `<SERVER>` |
| | Location | `<REGION>` |
| | Authentication method | **Use Microsoft Entra-only authentication** |
| | Microsoft Entra admin | **Set admin** → choose **yourself** |
| Networking | Allow Azure services… | **No** |
| | Add current client IP address | **Yes** |

**Review + create → Create.** Takes ~1 minute.

**Why Entra-only:** no SQL admin password to store, rotate or leak. Everything
downstream — the managed identity, your own access — authenticates through
Entra. Nothing in this system needs a password.

**Why "Allow Azure services = No":** that toggle creates a `0.0.0.0` firewall
rule admitting **every Azure subscription in the world**, not just yours. Step 8
gives the agent a much narrower route.

> There is no "connectivity method" choice when creating a *server* — that
> appears on the *database* blade. Public vs private access is configured
> afterwards, in step 3.

---

## 3. Check public network access

**Portal → `<SERVER>` → Security → Networking → Public network access**

| What you see | What to do |
|---|---|
| **Selected networks**, with your IP listed | Continue to step 4 |
| **Disabled** | Read the box below before continuing |

### If it says Disabled

Many corporate tenants apply an Azure Policy that forces public network access
off on SQL servers. **This was observed on the reference deployment**, in two
different regions.

Set **Public network access** to **Selected networks** and **Save**. Then
re-check after a minute.

**If the policy puts it back to Disabled, that is the policy winning, and it
will keep winning.** What that means in practice:

| Path | Affected? |
|---|---|
| Job agent → monitored databases | No — uses the private endpoint from step 8 |
| **You → the repository** (SSMS, steps 9–13) | **Yes — blocked** |
| **Dashboard generator → the repository** (step 14) | **Yes — blocked** |

So **collection keeps running and the dashboard stops refreshing** — a failure
mode that looks like a broken dashboard rather than a network policy.

Your options, in order of preference:

1. **Run steps 9–14 from a VNet-connected host** (a small VM, Bastion, or an
   existing jump box) and add a **private endpoint for your own access** —
   `<SERVER>` → *Networking → Private access → + Create a private endpoint*.
   This is the durable answer.
2. **Request a policy exemption** for this resource group.
3. **Re-enable public access each time you need it.** Works, but you will be
   doing it repeatedly, and an unattended dashboard refresh will fail silently
   between times.

Also confirm on the **Overview** blade that **Microsoft Entra admin** shows your
name.

---

## 4. Firewall rule for your workstation

Only possible while public access is **Selected networks** — firewall rules
cannot be added to a disabled endpoint.

**Portal → `<SERVER>` → Security → Networking → Firewall rules**

Your IP should already be listed from step 2. If not, click
**+ Add your client IPv4 address**, then **Save**.

> This records the IP you have **right now**. Changing networks, connecting to a
> VPN, or an ISP reassignment will all break it, and the error you get
> (`Client with IP address '...' is not allowed`) names the new address — just
> add that one too.

---

## 5. Database

**Portal → SQL databases → + Create**

| Field | Value |
|---|---|
| Resource group | `<RESOURCE-GROUP>` |
| Database name | `<DATABASE>` |
| Server | `<SERVER>` |
| Elastic pool | **No** |
| Workload environment | Production |

Then **Compute + storage → Configure database**:

| Field | Value |
|---|---|
| Service tier | **Standard (DTU-based)** |
| DTUs | **S2 — 50 DTU** |

**Backup storage redundancy:** *Locally-redundant*. This is a rebuildable
monitoring repository, not business data.

**Review + create → Create.** Takes ~3 minutes.

### Sizing

| Monitored databases | First-month growth | Tier |
|---|---|---|
| 1–10 | ~4 GB | **S2** |
| 10–50 | ~20 GB | S3 / GP_Gen5_4 |
| 50–200 | ~80 GB | GP_Gen5_8 |

> **Do not choose Serverless with auto-pause.** The job agent polls constantly,
> so the database never pauses — you pay serverless rates for a database that
> behaves as provisioned. S1 is the documented minimum for a job database.

---

## 6. Managed identity

**Portal → search `Managed Identities` → + Create**

| Field | Value |
|---|---|
| Resource group | `<RESOURCE-GROUP>` |
| Region | `<REGION>` |
| Name | `<UMI>` |

**Review + create → Create.**

> **This must exist before step 7.** The identity is attached when the job agent
> is created and **cannot be added or changed afterwards** — getting this out of
> order means deleting the agent and starting it again.

---

## 7. Elastic Job Agent

**Portal → search `Elastic Job agents` → + Create**

| Field | Value |
|---|---|
| Subscription | `<SUBSCRIPTION>` |
| Resource group | `<RESOURCE-GROUP>` |
| Name | `<AGENT>` |
| Location | `<REGION>` |
| Job database | **Select** → server `<SERVER>` → database `<DATABASE>` |
| Identity | **User-assigned** → **Add** → `<UMI>` |

**Review + create → Create.**

**This takes about 10 minutes.** When it finishes, the agent will have created
`jobs` and `jobs_internal` schemas inside `<DATABASE>`.

---

## 8. Create the private endpoint

The agent's connection to a server **as a target** goes through the
firewall/private-endpoint path — including when the agent, the job database and
the repository are all on `<SERVER>`. Sharing a server does not exempt it.

Without this, every collection step fails with:

```
Failed to connect to the target database: Cannot open server '<SERVER>'
requested by the login. Client with IP address '20.x.x.x' is not allowed
to access the server.
```

That IP is the **agent's**, not yours, and it is not stable — do not try to
allow-list it.

**Create it:**

1. **Portal → `<AGENT>` → Security → Private endpoints**
2. **+ Add a server and create private endpoint**
3. Choose `<SERVER>` · give it any name · **Create**
4. Status becomes **Pending**

**Approve it:**

5. **Portal → `<SERVER>` → Security → Networking → Private access**
6. Select the pending connection → **Approve**

Status must read **Approved**. Allow up to 5 minutes to take effect.

> Microsoft operates this endpoint for you — no VNet, subnet or DNS to supply.
> Repeat it once per **logical server** you monitor, not per database.

---

## 9. Connect with SSMS

| Field | Value |
|---|---|
| Server name | `<SERVER>.database.windows.net` |
| Authentication | **Microsoft Entra MFA** |
| **Options → Connect to database** | `<DATABASE>` **set this explicitly** |

> Set the default database explicitly. Azure SQL reports
> a missing or unreachable database as a **login failure**, which sends you
> hunting an auth problem that isn't there.

Verify:

```sql
SELECT DB_NAME() AS db, SUSER_SNAME() AS me, @@SERVERNAME AS srv;
```

`srv` must return the **short** name (`ehd-server-01`), not the FQDN. That short
form matters in step 12.

---

## 10. Deploy the repository schema

Open each file from `01-central\` and run it **in this order**. Each depends on
the one before; if one fails, fix it before continuing.

```
01-central\00-schemas-and-config.sql
01-central\01-core-tables.sql
01-central\02-normalize.sql
01-central\03-views.sql
01-central\04-job-health.sql
01-central\05-alerts.sql
01-central\06-purge.sql
```

**Nothing to edit in these files.**

In the `04-job-health.sql` output, look for:

```
jobs schema found - creating live job-health views.
```

If it instead reports creating stubs, the agent from step 7 has not finished —
wait, then re-run that one file.

**Verify:**

```sql
SELECT Tables_ = COUNT(*) FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE s.name IN ('cfg','core','stg');
SELECT Procs_ = COUNT(*) FROM sys.procedures p
JOIN sys.schemas s ON s.schema_id = p.schema_id WHERE s.name IN ('cfg','core');
SELECT Scripts = COUNT(*) FROM cfg.DeployLog;
```

Expect **28 tables**, **10 procedures**, **7 scripts**.

---

## 11. Create the agent's database user

The managed identity exists in Azure but has **no database user** yet. Nothing
will collect until it does.

### No `CREATE LOGIN` is needed here

`CREATE USER ... FROM EXTERNAL PROVIDER` creates a **contained** database user
mapped straight to the Entra principal. For this topology — the agent writing
results to `<DATABASE>` and collecting from databases registered individually as
`SqlDatabase` targets — that is sufficient, and **no login in `master` is
required**. This deployment was built and verified that way.

A login in `master` becomes necessary in exactly two cases, both covered in
[PORTAL-ADD-DATABASE.md](PORTAL-ADD-DATABASE.md):

| Case | Why |
|---|---|
| A target group member of type **`SqlServer`** (whole server) | The agent connects to that server's `master` to enumerate databases, so the identity must exist there |
| The **zero-footprint** permission model on a target | `##MS_ServerStateReader##` and friends are *server* roles, so they need a server principal |

Neither applies to step 13 below, which registers a single database.

### The grants

> **Change `ehd-agent-umi` to your `<UMI>` name in every line below.** The name
> must match the managed identity resource exactly — Entra resolves it by
> display name.

```sql
CREATE USER [ehd-agent-umi] FROM EXTERNAL PROVIDER;

GRANT CREATE TABLE TO [ehd-agent-umi];
GRANT ALTER   ON SCHEMA::stg  TO [ehd-agent-umi];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::stg  TO [ehd-agent-umi];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::core TO [ehd-agent-umi];
GRANT SELECT  ON SCHEMA::cfg  TO [ehd-agent-umi];
GRANT INSERT, UPDATE ON OBJECT::cfg.Target TO [ehd-agent-umi];
GRANT EXECUTE ON SCHEMA::core TO [ehd-agent-umi];
GRANT EXECUTE ON SCHEMA::cfg  TO [ehd-agent-umi];
GRANT VIEW DEFINITION TO [ehd-agent-umi];
GRANT VIEW DATABASE STATE TO [ehd-agent-umi];

ALTER ROLE jobs_reader ADD MEMBER [ehd-agent-umi];

DENY INSERT, UPDATE, DELETE, ALTER, EXECUTE ON SCHEMA::jobs          TO [ehd-agent-umi];
DENY INSERT, UPDATE, DELETE, ALTER, CONTROL  ON SCHEMA::jobs_internal TO [ehd-agent-umi];
```

Three of those lines are not obvious, and each was a real failure before it was
understood:

- **`GRANT EXECUTE ON SCHEMA::cfg`** — `SELECT` does not cover scalar functions,
  and the normalizer reads settings through `cfg.fn_Int` inside dynamic SQL,
  where ownership chaining does not apply. Without it, every collection job
  succeeds and only normalization fails — *and only when the agent runs it*,
  because you already have `EXECUTE` when you test it by hand.
- **`GRANT INSERT, UPDATE ON OBJECT::cfg.Target`** — the daily registry sync
  writes here. Object-scoped deliberately: `SCHEMA::cfg` would also hand the job
  write access to `cfg.Setting`, which holds your retention and alert
  thresholds.
- **No `CONTROL` in the `jobs` DENY** — `CONTROL` implies *every* permission
  including `SELECT`, and `DENY` beats both `GRANT` and role membership. Adding
  it silently revokes the read access every job-health view depends on.

**Verify both halves of the boundary:**

```sql
SELECT SchemaName = s.name,
       WritesDenied = MAX(CASE WHEN p.state_desc='DENY'
            AND p.permission_name IN ('INSERT','UPDATE','DELETE','ALTER','EXECUTE','CONTROL')
            THEN 1 ELSE 0 END),
       ReadBlocked  = MAX(CASE WHEN p.state_desc='DENY'
            AND p.permission_name IN ('SELECT','CONTROL') THEN 1 ELSE 0 END)
FROM sys.database_permissions p
JOIN sys.schemas s ON s.schema_id = p.major_id
WHERE p.class = 3
  AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID('ehd-agent-umi')
  AND s.name IN ('jobs','jobs_internal')
GROUP BY s.name;
```

| SchemaName | WritesDenied | ReadBlocked |
|---|---|---|
| `jobs` | 1 | **0** |
| `jobs_internal` | 1 | 1 |

`ReadBlocked` **must be 0 on `jobs`**. If it comes back 1, a `CONTROL` denial
has crept in and every job-health view is broken. Fix with:

```sql
REVOKE CONTROL ON SCHEMA::jobs FROM [ehd-agent-umi];
```

---

## 12. Deploy the jobs

Run these **in order** from `03-elasticjobs\`:

```
20-agent-setup.sql      creates the target groups the others attach to
21-jobs-frequent.sql
22-jobs-standard.sql
23-jobs-daily.sql
24-jobs-process.sql
25-jobs-setup.sql
```

> **Optional edit.** These files contain a literal
> `N'ehd-server.database.windows.net'` as the documented default output server.
> **You do not need to change it** — each script reads
> `SERVERPROPERTY('ServerName')` at deploy time and corrects itself. Update it
> only if you want the file to match your estate on paper.

**Verify:**

```sql
SELECT j.job_name, j.enabled,
       Steps = (SELECT COUNT(*) FROM jobs.jobsteps s
                WHERE s.job_id = j.job_id AND s.job_version = j.job_version)
FROM   jobs.jobs j WHERE j.job_name LIKE 'EHD[_]%' ORDER BY j.job_name;
```

| Job | Enabled | Steps |
|---|---|---|
| `EHD_Collect_Daily` | True | 6 |
| `EHD_Collect_Frequent` | True | 5 |
| `EHD_Collect_Standard` | True | 7 |
| `EHD_Process_Daily` | True | 3 |
| `EHD_Process_Frequent` | True | 2 |
| `EHD_Setup_Targets` | **False** | 2 |

`EHD_Setup_Targets` is disabled on purpose — it is the only job that can write
to a monitored database. Leave it alone unless you deploy the optional Extended
Events sessions.

---

## 13. Register the first target

> **Change both server names to your `<SERVER>`.** They are deliberately
> different forms — see the warning below.

```sql
-- a) collection: tells the agent where to run.  FULL domain name.
EXEC jobs.sp_add_target_group_member
     @target_group_name = 'EHD_AllTargets',
     @membership_type   = 'Include',
     @target_type       = 'SqlDatabase',
     @server_name       = 'ehd-server-01.database.windows.net',
     @database_name     = 'EnterpriseHealth';

-- b) registry: drives the fleet scorecard.  SHORT name.
EXEC cfg.usp_RegisterTarget
     @ServerName   = N'ehd-server-01',
     @DatabaseName = N'EnterpriseHealth',
     @Criticality  = N'High';
```

> **The two use different name forms and that is not a typo.** The target
> group needs the **FQDN** because the agent dials it. `cfg.Target` needs the
> **short name**, because every collection query stamps its rows with
> `@@SERVERNAME`, which on Azure SQL returns the short form. Mismatch them and
> the database collects perfectly while showing "never reported" forever.
>
> Use `cfg.usp_RegisterTarget` rather than a raw `INSERT` — it trims the name
> for you.

`Environment` defaults to `Default` if you omit it, and becomes a filter on the
dashboard.

**Verify:**

```sql
SELECT * FROM jobs.target_group_members;
SELECT ServerName, DatabaseName, Environment FROM cfg.Target;
```

`cfg.Target.ServerName` must read `ehd-server-01` — **no** `.database.windows.net`.

---

## 14. First run

Do not wait for the schedules.

```sql
DECLARE @f uniqueidentifier, @s uniqueidentifier, @d uniqueidentifier;
EXEC jobs.sp_start_job 'EHD_Collect_Frequent', @f OUTPUT;
EXEC jobs.sp_start_job 'EHD_Collect_Standard', @s OUTPUT;
EXEC jobs.sp_start_job 'EHD_Collect_Daily',    @d OUTPUT;
SELECT frequent = @f, standard = @s, daily = @d;
```

> A **separate output variable per job**. Reusing one throws
> `Job Execution with id '...' already exists`.

Wait ~2 minutes:

```sql
SELECT job_name, step_name, lifecycle, target_database_name,
       msg = LEFT(last_message, 100)
FROM   jobs.job_executions
WHERE  step_id IS NOT NULL
  AND  start_time > DATEADD(MINUTE, -5, SYSUTCDATETIME())
ORDER BY job_name, step_id;
```

Everything must say `Succeeded`.

| Message | Cause |
|---|---|
| `Client with IP address '20.x.x.x' is not allowed` | Step 8 incomplete — private endpoint not **Approved** |
| `Login failed` / `Cannot open database` | Step 11 — the agent's user does not exist |
| All `Succeeded` but `target_database_name` NULL everywhere | Step 13a — target group is empty, so the job ran zero times and reported success |

Confirm the staging tables now exist — **18 of them**:

```sql
SELECT StagingTables = COUNT(*) FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = 'stg';
```

Then process:

```sql
DECLARE @a uniqueidentifier, @b uniqueidentifier;
EXEC jobs.sp_start_job 'EHD_Process_Frequent', @a OUTPUT;
EXEC jobs.sp_start_job 'EHD_Process_Daily',    @b OUTPUT;
```

---

## 15. The verification gate

```sql
EXEC core.usp_Normalize;

SELECT ProcessRunId, StepName, Status, RowsAffected,
       err = LEFT(ISNULL(ErrorMessage,''), 80)
FROM   core.ProcessRun
WHERE  StartedUtc > DATEADD(MINUTE, -20, SYSUTCDATETIME())
ORDER BY ProcessRunId DESC;

SELECT Tier, AgeMin, LimitMin, Attempts24h, Failures24h, Diagnosis
FROM   core.vw_FeedDiagnosis;

SELECT * FROM core.vw_FleetScorecard;
```

**Pass criteria — all four:**

| Check | Required |
|---|---|
| `usp_Normalize` | `FeedsSkipped = 0`, `FeedsFailed = 0` |
| `core.ProcessRun` | no `Failed` or `PartialSuccess` rows |
| `vw_FeedDiagnosis` | every tier `Healthy`, **`Attempts24h` NOT NULL** |
| `vw_FleetScorecard` | one row, `CollectionState = OK` |

**Watch `Attempts24h` specifically.** NULL there while jobs are plainly
succeeding means job history is not joining to targets, and the diagnosis view
will claim "no job has run in 24 h" on a perfectly healthy estate.

If you skipped the Extended Events sessions (the default), `core.ErrorEvent`,
`core.Deadlock` and `core.WaitEvent` stay empty and `stg.XeErrors` /
`stg.XeBlocking` exist with 0 rows. **That is correct** — `FeedsSkipped` should
still be `0`.

For a fuller report, run `tests\verify-staging-schema.sql` and read the
**SUMMARY** verdict.

---

## 16. Generate the dashboard

The only step with no Portal equivalent. From the repository root:

> **Change the server name.**

```powershell
.\04-dashboard\New-EnterpriseDashboard.ps1 `
    -CentralServer   ehd-server-01.database.windows.net `
    -CentralDatabase EnterpriseHealth `
    -OutputPath      .\04-dashboard\estate.html
```

| Parameter | Note |
|---|---|
| `-CentralServer` | **FQDN**, not the short name |
| `-CentralDatabase` | `<DATABASE>` |
| `-OutputPath` | Set it. The default overwrites `dashboard.html`, which is the **template** |

Authentication falls back through managed identity → Azure CLI → interactive
browser, so an existing `az login` is enough. If it cannot connect:

```powershell
$t = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
.\04-dashboard\New-EnterpriseDashboard.ps1 -CentralServer ehd-server-01.database.windows.net `
    -CentralDatabase EnterpriseHealth -OutputPath .\04-dashboard\estate.html -AccessToken $t
```

Open `estate.html`. One database, mostly green. The capacity forecast needs a
few days of history before it says anything useful.

---

## Done — what happens next

| Job | Schedule |
|---|---|
| `EHD_Collect_Frequent` | every 5 min |
| `EHD_Collect_Standard` | every 30 min |
| `EHD_Collect_Daily` | daily |
| `EHD_Process_Frequent` | every 5 min — normalize + alerts |
| `EHD_Process_Daily` | daily — purge + registry sync |

Each morning:

```sql
SELECT * FROM core.vw_FleetSummary;
SELECT * FROM core.vw_OpenAlerts WHERE Severity = 'Critical' ORDER BY RaisedUtc;
SELECT * FROM core.vw_FeedDiagnosis WHERE Diagnosis <> 'Healthy';
```

To add more databases, see **[PORTAL-ADD-DATABASE.md](PORTAL-ADD-DATABASE.md)**.

---

## Quick troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Server creation fails, *name already exists* | `<SERVER>` is globally unique | Pick another name, update §0 |
| `Public network access` keeps reverting to Disabled | Tenant Azure Policy | §3 — private endpoint for your own access, or an exemption |
| `Connection was denied... Deny Public Network Access` (47073) | As above | As above |
| `Client with IP address '20.x.x.x' is not allowed` | Agent private endpoint not Approved | §8 — the IP is the agent's and is not stable |
| `Client with IP address '<your ip>' is not allowed` | Your IP changed | §4 — add the address named in the error |
| Jobs `Succeeded`, no `stg.*` tables, `target_database_name` NULL | Empty target group | §13a |
| Only `01_Normalize` fails, and only when the agent runs it | Missing `GRANT EXECUTE ON SCHEMA::cfg` | §11 |
| `FeedsSkipped` never reaches 0 | Staging column mismatch | Run `tests\verify-staging-schema.sql` |
| `Attempts24h` NULL despite healthy jobs | Job-history join broken | Re-run `01-central\04-job-health.sql` |
| `Invoke-Sqlcmd is not recognized` | `SqlServer` module unavailable | The generator now falls back automatically — make sure you are on the current script |
