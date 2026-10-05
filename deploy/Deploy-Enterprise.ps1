<#
.SYNOPSIS
    Deploys the Enterprise Health Dashboard in the correct order.

.DESCRIPTION
    Everything lands in ONE Azure SQL Database, which is both the Elastic Job
    Agent's job database and the central repository. The agent owns the [jobs]
    schema; we own [cfg], [stg] and [core].

    Two phases run against that database, plus an optional third that does not:

        1. CENTRAL   -> schemas, tables, views, the alert engine, retention,
                        and the job-health views. All ours.

        2. AGENT     -> credentials, target groups, job definitions. Same
                        database - the agent's own schema sits alongside.

        3. TARGETS   -> the monitored databases. OPTIONAL, and the only part
                        that touches a vendor database at all. Covers
                        permissions, two XE sessions, and Query Store settings.

    The target step is gated behind -IncludeTargets and prints exactly what it
    would do rather than running it. If your compliance position is "nothing may
    be created in the vendor database", skip it entirely - you still get roughly
    70% of the signal from DMV polling alone.

    ORDER MATTERS TWICE:
      * within phase 1, views depend on tables and alerts depend on views
      * 04-job-health.sql is re-run at the end of phase 2, because its views
        read jobs.job_executions, which does not exist until the Elastic Job
        Agent has been created against this database

.PARAMETER CentralServer
    Logical server FQDN, e.g. ehd-sql.database.windows.net

.PARAMETER CentralDatabase
    The one database, e.g. EnterpriseHealth

.PARAMETER Phase
    Which part to deploy: Central, Agent, All. Default All.

.PARAMETER IncludeTargets
    Also print (not run) the target-side scripts, with the exact list of
    databases they would be applied to.

.PARAMETER WhatIf
    Show the execution plan without running anything.

.EXAMPLE
    # everything, in order
    .\Deploy-Enterprise.ps1 `
        -CentralServer ehd-sql.database.windows.net -CentralDatabase EnterpriseHealth

.EXAMPLE
    # repository only - do this BEFORE creating the Elastic Job Agent
    .\Deploy-Enterprise.ps1 -Phase Central `
        -CentralServer ehd-sql.database.windows.net -CentralDatabase EnterpriseHealth

.EXAMPLE
    # jobs only - do this AFTER the agent exists
    .\Deploy-Enterprise.ps1 -Phase Agent `
        -CentralServer ehd-sql.database.windows.net -CentralDatabase EnterpriseHealth
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $CentralServer,
    [Parameter(Mandatory)][string] $CentralDatabase,
    [ValidateSet('Central','Agent','All')][string] $Phase = 'All',
    [switch] $IncludeTargets,
    [string] $AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Write-Head {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Invoke-Script {
    param(
        [string]$Path, [string]$Server, [string]$Database,
        [hashtable]$Variables = @{}
    )
    $name = Split-Path -Leaf $Path
    if (-not (Test-Path $Path)) { throw "Script not found: $Path" }

    if (-not $PSCmdlet.ShouldProcess("$Database on $Server", "run $name")) {
        Write-Host ("  [WhatIf] {0}" -f $name) -ForegroundColor DarkGray
        return
    }

    Write-Host ("  -> {0}" -f $name) -NoNewline
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $splat = @{
        ServerInstance = $Server
        Database       = $Database
        InputFile      = $Path
        QueryTimeout   = 1800
        ErrorAction    = 'Stop'
        Verbose        = $false
    }
    if ($AccessToken) { $splat['AccessToken'] = $AccessToken }
    if ($Variables.Count) {
        # Invoke-Sqlcmd wants "KEY=VALUE" strings for -Variable
        $splat['Variable'] = @($Variables.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    }

    try {
        Invoke-Sqlcmd @splat | Out-Null
        $sw.Stop()
        Write-Host ("  ok ({0:N1}s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    catch {
        $sw.Stop()
        Write-Host "  FAILED" -ForegroundColor Red
        Write-Host ("     {0}" -f $_.Exception.Message) -ForegroundColor Red
        throw
    }
}

Import-Module SqlServer -ErrorAction Stop

#==============================================================================
# PHASE 1 - CENTRAL REPOSITORY
#
# Order is not negotiable. Views reference tables, the alert engine references
# views, and retention references the staging purge defined in normalize.
#==============================================================================
if ($Phase -in @('Central','All')) {
    Write-Head "PHASE 1 - CENTRAL REPOSITORY  ($CentralDatabase on $CentralServer)"

    $centralScripts = @(
        '00-schemas-and-config.sql'   # schemas, cfg.Setting, cfg.Target, ProcessRun, FeedArrival
        '01-core-tables.sql'          # the ~22 modelled tables
        '02-normalize.sql'            # stg -> core, fn_StagingReady, usp_PurgeStaging
        '03-views.sql'                # analysis + fleet views
        '04-job-health.sql'           # job views - stubs if the agent does not exist yet
        '05-alerts.sql'               # raise / resolve / evaluate (reads vw_JobHealth)
        '06-purge.sql'                # retention + storage report
    )

    foreach ($s in $centralScripts) {
        Invoke-Script -Path (Join-Path $root "01-central\$s") `
                      -Server $CentralServer -Database $CentralDatabase
    }

    if ($PSCmdlet.ShouldProcess("$CentralDatabase", "verify deployment")) {
        $check = Invoke-Sqlcmd -ServerInstance $CentralServer -Database $CentralDatabase -Query @"
SELECT Tables_ = (SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='core'),
       Views_  = (SELECT COUNT(*) FROM sys.views v JOIN sys.schemas s ON s.schema_id=v.schema_id WHERE s.name='core'),
       Procs_  = (SELECT COUNT(*) FROM sys.procedures p JOIN sys.schemas s ON s.schema_id=p.schema_id WHERE s.name='core'),
       Settings_ = (SELECT COUNT(*) FROM cfg.Setting);
"@ -ErrorAction Stop

        Write-Host ""
        Write-Host ("  core tables : {0}" -f $check.Tables_)
        Write-Host ("  core views  : {0}" -f $check.Views_)
        Write-Host ("  core procs  : {0}" -f $check.Procs_)
        Write-Host ("  settings    : {0}" -f $check.Settings_)

        if ($check.Views_ -lt 18) {
            Write-Warning "Expected at least 18 views in core. Something did not deploy - re-run with -Verbose."
        }
    }
}

#==============================================================================
# PHASE 2 - ELASTIC JOB AGENT
#
# NOTE ON IDENTITY: the job steps authenticate with the agent's USER-ASSIGNED
# MANAGED IDENTITY - there are no credentials to create and no passwords to
# rotate. What you DO need is the identity's login in each target server's
# master, in three server roles. Read 02-targets\10-target-permissions.sql
# before running this phase - it tells you exactly what to create and where.
#==============================================================================
if ($Phase -in @('Agent','All')) {
    Write-Head "PHASE 2 - ELASTIC JOBS  ($CentralDatabase on $CentralServer)"
    # No sqlcmd variables: the job scripts resolve the server from the live
    # connection (SERVERPROPERTY('ServerName')) and the database from DB_NAME().

    $agentScripts = @(
        '20-agent-setup.sql'      # managed-identity grants + target groups
        '21-jobs-frequent.sql'    # 5 steps, every 5 min
        '22-jobs-standard.sql'    # 7 steps, every 30 min
        '23-jobs-daily.sql'       # 6 steps, daily tier
        '24-jobs-process.sql'     # normalize -> alerts -> purge, in the central db
        '25-jobs-setup.sql'       # OPTIONAL target setup - created disabled, never auto-runs
    )

    foreach ($s in $agentScripts) {
        Invoke-Script -Path (Join-Path $root "03-elasticjobs\$s") `
                      -Server $CentralServer -Database $CentralDatabase
    }

    #--------------------------------------------------------------------------
    # Re-run the job-health views now that the [jobs] schema definitely exists.
    #
    # On a first deployment these were created as empty stubs, because
    # 01-central ran before the Elastic Job Agent was pointed at this database.
    # Running the script again swaps the stubs for the real definitions, which
    # is what makes the dashboard's failure counts and error text live.
    #--------------------------------------------------------------------------
    Invoke-Script -Path (Join-Path $root '01-central\04-job-health.sql') `
                  -Server $CentralServer -Database $CentralDatabase

    if ($PSCmdlet.ShouldProcess($CentralDatabase, "confirm job-health views are live")) {
        $jh = Invoke-Sqlcmd -ServerInstance $CentralServer -Database $CentralDatabase -Query @"
SELECT IsStub = CASE WHEN OBJECT_ID('jobs.job_executions') IS NULL THEN 1 ELSE 0 END,
       HasView= CASE WHEN OBJECT_ID('core.vw_JobHealth')   IS NULL THEN 0 ELSE 1 END;
"@ -ErrorAction Stop
        if ($jh.IsStub -eq 1) {
            Write-Warning "jobs.job_executions still not found - the Elastic Job Agent is not pointed at [$CentralDatabase]. Create it, then re-run: Deploy-Enterprise.ps1 -Phase Agent"
        } else {
            Write-Host "  job-health views are live (failure counts and error text will populate)" -ForegroundColor Green
        }
    }

    if ($PSCmdlet.ShouldProcess("$CentralDatabase", "list jobs")) {
        $jobs = Invoke-Sqlcmd -ServerInstance $CentralServer -Database $CentralDatabase -Query @"
SELECT j.job_name, j.enabled, j.schedule_interval_type, j.schedule_interval_count,
       Steps = (SELECT COUNT(*) FROM jobs.jobsteps s
                WHERE s.job_id = j.job_id AND s.job_version = j.job_version)
FROM   jobs.jobs j WHERE j.job_name LIKE 'EHD[_]%' ORDER BY j.job_name;
"@ -ErrorAction Stop
        Write-Host ""
        if ($null -ne $jobs) { ,@($jobs) | Format-Table -AutoSize | Out-String | Write-Host }
    }
}

#==============================================================================
# PHASE 3 - TARGETS  (informational only, never executed by this script)
#==============================================================================
if ($IncludeTargets) {
    Write-Head "PHASE 3 - TARGET DATABASES  (not executed - review required)"

    Write-Host ""
    Write-Host "  These scripts are the ONLY part of the system that creates anything" -ForegroundColor Yellow
    Write-Host "  inside a monitored database. This script will not run them for you." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    02-targets\10-target-permissions.sql   grants only - no objects created"
    Write-Host "    02-targets\11-target-xe-sessions.sql   creates 2 XE sessions (ring buffer only)"
    Write-Host "    02-targets\12-target-querystore.sql    ALTER DATABASE SET QUERY_STORE"
    Write-Host ""
    Write-Host "  Footprint if you run all three:" -ForegroundColor Yellow
    Write-Host "    - 1 contained user (or none, if you use ##MS_ServerStateReader## in master)"
    Write-Host "    - 2 Extended Events sessions, memory-resident, no blob, no credential"
    Write-Host "    - Query Store enabled at READ_WRITE (usually already on)"
    Write-Host "    - ZERO tables, ZERO procedures, ZERO schema changes"
    Write-Host ""
    Write-Host "  If you skip this phase entirely, you still get:" -ForegroundColor Green
    Write-Host "    resource usage, waits, blocking, sessions, space, IO, query stats,"
    Write-Host "    index usage, missing indexes, fragmentation, security snapshots."
    Write-Host "  You lose: error events and deadlock graphs (both XE-only)."
    Write-Host ""

    if ($CentralServer -and $CentralDatabase -and $PSCmdlet.ShouldProcess("targets", "list")) {
        try {
            $tg = Invoke-Sqlcmd -ServerInstance $CentralServer -Database $CentralDatabase -Query @"
SELECT g.target_group_name, m.membership_type, m.target_type, m.server_name, m.database_name
FROM   jobs.target_group_members m
JOIN   jobs.target_groups g ON g.target_group_id = m.target_group_id
WHERE  g.target_group_name LIKE 'EHD[_]%' ORDER BY g.target_group_name, m.database_name;
"@ -ErrorAction Stop
            Write-Host "  Current target group membership:" -ForegroundColor Cyan
            if ($null -ne $tg) { ,@($tg) | Format-Table -AutoSize | Out-String | Write-Host }
            else { Write-Host "    (none yet)" -ForegroundColor DarkGray }
        } catch {
            Write-Host ("  Could not read target groups: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        }
    }
}

#==============================================================================
# NEXT STEPS
#==============================================================================
Write-Head "NEXT STEPS"
Write-Host ""
Write-Host "  1. Register the databases you want to monitor:" -ForegroundColor White
Write-Host "       -- in $CentralDatabase" -ForegroundColor DarkGray
Write-Host "       INSERT cfg.Target (ServerName, DatabaseName, Environment, Criticality, IsVendorOwned)"
Write-Host "       VALUES (N'sql-prod.database.windows.net', N'AppDb', N'Production', N'High', 1);"
Write-Host ""
Write-Host "  2. Add them to the collection target group (same database):" -ForegroundColor White
Write-Host "       EXEC jobs.sp_add_target_group_member 'EHD_AllTargets', 'Include',"
Write-Host "            'SqlDatabase', 'sql-prod.database.windows.net', 'AppDb';"
Write-Host ""
Write-Host "  3. Run one collection job by hand - do not wait 5 minutes to find a typo:" -ForegroundColor White
Write-Host "       EXEC jobs.sp_start_job 'EHD_Collect_Frequent';"
Write-Host ""
Write-Host "  4. VERIFY THE STAGING CONTRACT. This is the one assumption the" -ForegroundColor Yellow
Write-Host "     build could not check for you:" -ForegroundColor Yellow
Write-Host "       sqlcmd -S $CentralServer -d $CentralDatabase -G -i tests\verify-staging-schema.sql"
Write-Host ""
Write-Host "  5. Normalize and evaluate:" -ForegroundColor White
Write-Host "       EXEC core.usp_Normalize;"
Write-Host "       EXEC core.usp_EvaluateAlerts;"
Write-Host ""
Write-Host "  6. Generate the dashboard:" -ForegroundColor White
Write-Host "       .\04-dashboard\New-EnterpriseDashboard.ps1 ``"
Write-Host "            -CentralServer $CentralServer -CentralDatabase $CentralDatabase"
Write-Host ""
