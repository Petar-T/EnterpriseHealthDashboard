# Add a database to the dashboard — Portal walkthrough

Onboarding an existing Azure SQL database into a working Enterprise Health
Dashboard. Assumes **[PORTAL-DEPLOY.md](PORTAL-DEPLOY.md)** is complete and the
fleet scorecard already shows at least one database.

**Time:** ~5 minutes on the same server, ~15 on a new one.

---

## 0. Variables — set these once

| Placeholder | What it is | Example | Where you find it |
|---|---|---|---|
| `<TARGET-SERVER>` | **Short** name of the server hosting the new database | `sql-prod-weu` | Portal → SQL databases → *Server name* column, minus the domain |
| `<TARGET-SERVER-FQDN>` | Same server, full domain name | `sql-prod-weu.database.windows.net` | Portal → the server → Overview → *Server name* |
| `<TARGET-DATABASE>` | Database to monitor | `AppDb` | Exact name, case as created |
| `<UMI>` | The **existing** identity from your deployment | `ehd-agent-umi` | Portal → Managed Identities |
| `<AGENT>` | The **existing** job agent | `ehd-agent` | Portal → Elastic Job agents |
| `<REPO-SERVER>` | Server hosting the repository | `ehd-server-01` | From the deployment guide |
| `<REPO-DATABASE>` | The repository database | `EnterpriseHealth` | From the deployment guide |

> **`<TARGET-SERVER>` is needed in both forms.** Short in one step, FQDN in
> another. This is the single most common onboarding mistake — see §4.

---

## 1. Which path?

| Situation | Steps | Why |
|---|---|---|
| Database is on **`<REPO-SERVER>`** | 3 → 4 → 5 | Network path already approved |
| Database is on a **different server** | 2 → 3 → 4 → 5 | Needs a private endpoint and possibly a `master` login |

Everything below works across **subscriptions**. Elastic Jobs target by server
name, and nothing in the design is subscription-aware.

> **The real boundary is the Entra tenant, not the subscription.** The managed
> identity is a tenant-level object resolved by
> `CREATE USER ... FROM EXTERNAL PROVIDER`. A database in a *different tenant*
> cannot be onboarded this way.

---

## 2. Network path — new servers only

**Skip entirely if the database is on `<REPO-SERVER>`.**

Required even inside your own subscription, and even if you can reach the server
from SSMS yourself. The agent connects from Azure-internal addresses that are
not yours and are not stable.

**Create it:**

1. **Portal → `<AGENT>` → Security → Private endpoints**
2. **+ Add a server and create private endpoint**
3. Choose `<TARGET-SERVER>` · any name · **Create**
4. Status becomes **Pending**

**Approve it:**

5. **Portal → `<TARGET-SERVER>` → Security → Networking → Private access**
6. Select the pending connection → **Approve**

Must read **Approved**. Allow up to 5 minutes.

> Once per **logical server**, not per database. A second database on the same
> server needs no network work at all.

---

## 3. Permissions on the target

Two options. Pick one.

### Option A — contained user (default choice)

**Run in `<TARGET-DATABASE>`** — not `master`, not the repository.

> **Change `ehd-agent-umi` to your `<UMI>`.**

```sql
CREATE USER [ehd-agent-umi] FROM EXTERNAL PROVIDER;

GRANT VIEW DATABASE STATE TO [ehd-agent-umi];   -- the DMVs
GRANT VIEW DEFINITION     TO [ehd-agent-umi];   -- object names for index and table feeds
```

That is the entire footprint: **one user, two grants, no objects created.**

Deliberately **not** granted: `db_datareader`, any `CREATE`, any `ALTER`.
`VIEW DATABASE STATE` exposes DMVs only — never table contents.

> Add `GRANT ALTER ANY DATABASE EVENT SESSION` **only** if you intend to deploy
> the optional Extended Events sessions. Skipping them costs you error events
> and deadlock graphs; everything else works.

### Option B — server role, zero footprint in the database

Use this when a vendor or compliance position forbids creating anything inside
the monitored database, or when you want to onboard a **whole server**.

**Run in `master` on `<TARGET-SERVER>`.**

```sql
CREATE LOGIN [ehd-agent-umi] FROM EXTERNAL PROVIDER;

ALTER SERVER ROLE ##MS_DatabaseConnector## ADD MEMBER [ehd-agent-umi];
ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [ehd-agent-umi];
ALTER SERVER ROLE ##MS_DefinitionReader##  ADD MEMBER [ehd-agent-umi];
```

> **`##MS_DatabaseConnector##` is the one people miss.** The other two grant the
> right to **read once you are inside** a database; neither grants the right to
> **get inside** one. Omit it and every target fails with
> `Cannot open database ... requested by the login`, which looks like a firewall
> or naming fault and is neither.

**Verify — expect three rows:**

```sql
SELECT m.name AS MemberName, r.name AS RoleName
FROM   sys.server_role_members rm
JOIN   sys.server_principals r ON r.principal_id = rm.role_principal_id
JOIN   sys.server_principals m ON m.principal_id = rm.member_principal_id
WHERE  r.name LIKE '##MS[_]%';
```

| | Option A | Option B |
|---|---|---|
| Created in the monitored database | 1 user | **nothing** |
| Created in `master` | nothing | 1 login + 3 role memberships |
| Needs `master` access | No | Yes |
| Supports whole-server targets | **No** | Yes |
| Best for vendor databases | | **Yes** |

### Verify the read-only claim

Run **in `<TARGET-DATABASE>`**. This is the evidence to hand a vendor.

```sql
EXECUTE AS USER = 'ehd-agent-umi';

SELECT CanReadDmvs   = HAS_PERMS_BY_NAME(NULL,'DATABASE','VIEW DATABASE STATE'),
       CanCreate     = HAS_PERMS_BY_NAME(NULL,'DATABASE','CREATE TABLE'),
       CanAlter      = HAS_PERMS_BY_NAME(NULL,'DATABASE','ALTER'),
       BusinessTablesReadable = (
           SELECT COUNT(*) FROM sys.tables t
           WHERE SCHEMA_NAME(t.schema_id) NOT IN ('sys','INFORMATION_SCHEMA')
             AND HAS_PERMS_BY_NAME(QUOTENAME(SCHEMA_NAME(t.schema_id))
                 + '.' + QUOTENAME(t.name),'OBJECT','SELECT') = 1);

REVERT;
```

Required: `1`, `0`, `0`, **`0`**.

A non-zero `BusinessTablesReadable` means someone granted `db_datareader` or an
over-broad role, and the read-only story no longer holds.

---

## 4. Register it

**Run both in `<REPO-DATABASE>`** on `<REPO-SERVER>`.

> **Change the server name in both — to different forms.**

```sql
-- a) collection: where the agent runs.  FULL domain name.
EXEC jobs.sp_add_target_group_member
     @target_group_name = 'EHD_AllTargets',
     @membership_type   = 'Include',
     @target_type       = 'SqlDatabase',
     @server_name       = 'sql-prod-weu.database.windows.net',   -- <TARGET-SERVER-FQDN>
     @database_name     = 'AppDb';                               -- <TARGET-DATABASE>

-- b) registry: drives the fleet scorecard.  SHORT name.
EXEC cfg.usp_RegisterTarget
     @ServerName    = N'sql-prod-weu',        -- <TARGET-SERVER>, no domain
     @DatabaseName  = N'AppDb',               -- <TARGET-DATABASE>
     @Environment   = N'Production',
     @Owner         = N'payments-team@contoso.com',
     @Criticality   = N'High',
     @IsVendorOwned = 1;
```

> **The two forms are not a typo.** The target group needs the **FQDN**
> because the agent dials it. `cfg.Target` needs the **short name**, because
> every collection query stamps its rows with `@@SERVERNAME`, which on Azure SQL
> returns the short form.
>
> Get this wrong and the database **collects perfectly while showing "never
> reported" forever** — the data lands, but nothing can join it to the registry
> row. Use `cfg.usp_RegisterTarget`, never a raw `INSERT`: it trims the name for
> you.

### Optional metadata

| Parameter | Effect |
|---|---|
| `@Environment` | Becomes a **filter on the dashboard**. Omit and it defaults to `Default` |
| `@Owner` | Shown on the scorecard — who to call |
| `@Criticality` | Free text, e.g. `High` / `Tier1` |
| `@IsVendorOwned` | `1` flags it as vendor-owned in the UI |

No `@credential_name` anywhere — the agent uses its managed identity.

### Onboarding a whole server

**Option B permissions required.** New databases on that server are then picked
up automatically:

```sql
EXEC jobs.sp_add_target_group_member
     @target_group_name = 'EHD_AllTargets',
     @target_type       = 'SqlServer',
     @server_name       = 'sql-prod-weu.database.windows.net';

-- exclusions beat inclusions: protect a sensitive database explicitly
EXEC jobs.sp_add_target_group_member
     @target_group_name = 'EHD_AllTargets',
     @membership_type   = 'Exclude',
     @target_type       = 'SqlDatabase',
     @server_name       = 'sql-prod-weu.database.windows.net',
     @database_name     = 'VendorDb_DoNotTouch';
```

Databases discovered this way auto-register in `cfg.Target` on first data
arrival, with `Environment = Default`. Re-run `cfg.usp_RegisterTarget` later to
add ownership metadata.

---

## 5. Verify

Do not wait for the schedule.

```sql
DECLARE @f uniqueidentifier;
EXEC jobs.sp_start_job 'EHD_Collect_Frequent', @f OUTPUT;
SELECT @f;
```

Wait ~90 seconds. **Check it reached the new database specifically:**

```sql
SELECT job_name, step_name, lifecycle, target_database_name,
       msg = LEFT(last_message, 120)
FROM   jobs.job_executions
WHERE  step_id IS NOT NULL
  AND  start_time > DATEADD(MINUTE, -5, SYSUTCDATETIME())
ORDER BY start_time DESC;
```

`target_database_name` must show `<TARGET-DATABASE>` on `Succeeded` rows.

| Message | Cause | Fix |
|---|---|---|
| `Cannot open server ... Client with IP address '20.x.x.x' is not allowed` | Private endpoint missing or still Pending | §2. That IP is the agent's and is not stable — do not allow-list it |
| `Cannot open database ... requested by the login` | Option B without `##MS_DatabaseConnector##`, or Option A user missing | §3 |
| `Login failed for user '<token-identified principal>'` | Identity has no principal in the target | §3 |
| `Object reference not set to an instance of an object` | Target is a **serverless database that auto-paused**. The attempt itself wakes it | Re-run. See the note below |
| New database absent entirely | Target group member not added, or wrong FQDN | §4a |

Then normalize and look at the fleet:

```sql
EXEC core.usp_Normalize;

SELECT ServerName, DatabaseName, Tier, AgeMin, Attempts24h, Diagnosis
FROM   core.vw_FeedDiagnosis ORDER BY ServerName, DatabaseName, Tier;

SELECT ServerName, DatabaseName, Environment, CollectionState, HealthScore
FROM   core.vw_FleetScorecard ORDER BY ServerName, DatabaseName;
```

Both databases should now appear.

> **A new target reads stale for one full cycle.** `Daily` shows an age of hours
> until the daily job runs, and `vw_FeedDiagnosis` may say *"Recovering"* while
> a pre-onboarding failure ages out of the 24-hour window. Expected, not a
> fault.

Finally, refresh the dashboard:

```powershell
.\04-dashboard\New-EnterpriseDashboard.ps1 `
    -CentralServer   ehd-server-01.database.windows.net `
    -CentralDatabase EnterpriseHealth `
    -OutputPath      .\04-dashboard\estate.html
```

---

## Monitoring a serverless database — read this first

Serverless billing is per vCore-second, with auto-pause when idle.

> **Monitoring prevents auto-pause.** A 5-minute collection poll means the
> database never idles long enough to pause, so onboarding it **increases its
> cost**, and it can never auto-pause again while monitored.

That is usually acceptable for production, and usually not for dev/test. Decide
before onboarding, not after the bill.

The first collection attempt against a paused database typically fails with
`Object reference not set to an instance of an object` — the attempt triggers a
resume and the agent surfaces the race unhelpfully. Re-run; it succeeds.

---

## Removing a database

```sql
-- stop collecting
DECLARE @tid uniqueidentifier =
    (SELECT target_id FROM jobs.target_group_members
     WHERE  target_group_name = 'EHD_AllTargets'
       AND  database_name     = 'AppDb');          -- <TARGET-DATABASE>

EXEC jobs.sp_delete_target_group_member
     @target_group_name = 'EHD_AllTargets',
     @target_id         = @tid;

-- keep history, stop alerting
UPDATE cfg.Target SET IsEnabled = 0
WHERE  ServerName = N'sql-prod-weu' AND DatabaseName = N'AppDb';
```

> The `@target_id` must come from a variable — T-SQL does not accept a subquery
> directly as an `EXEC` parameter.

Setting `IsEnabled = 0` rather than deleting keeps the collected history
queryable and stops the registry raising "not reporting" alerts for a database
you intentionally dropped.

To remove the footprint from the target database itself:

```sql
-- in the target database (Option A)
DROP USER [ehd-agent-umi];

-- or in master (Option B)
DROP LOGIN [ehd-agent-umi];
```
