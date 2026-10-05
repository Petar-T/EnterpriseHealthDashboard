<#
.SYNOPSIS
    Compares every deployment script on disk against what is recorded as
    deployed in cfg.DeployLog, and tells you plainly which is which.

.DESCRIPTION
    "Is the database running the file I have on disk?" used to be answered by
    looking for a marker string inside a procedure definition. That is a
    heuristic, not a fact - the marker is usually also present in the comment
    describing it, so a stale deployment reports itself as current. That exact
    false positive occurred during this deployment.

    This script hashes each file and compares it to the SHA-256 recorded by
    deploy\Invoke-EhdSql.py when the file was last executed.

    Rows can disagree for an honest reason: deployments made through SSMS or
    sqlcmd are not recorded. An "unknown" verdict therefore means "nobody can
    prove what is running", which is different from "it is stale" - and both
    are different from "it matches".

.EXAMPLE
    .\tests\Test-Deployed.ps1 -CentralServer ehd-server.database.windows.net `
                              -CentralDatabase EnterpriseHealth
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CentralServer,
    [Parameter(Mandatory)][string] $CentralDatabase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root   = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $root 'deploy\Invoke-EhdSql.py'
if (-not (Test-Path $runner)) { throw "Runner not found: $runner" }

# --- what the database says is deployed -------------------------------------
# A single unambiguous marker row, rather than prose that has to be pattern
# matched out of the runner's table output.
$q = @'
SELECT Marker = CASE WHEN OBJECT_ID('cfg.DeployLog') IS NULL
                     THEN 'DEPLOYLOG_MISSING' ELSE 'DEPLOYLOG_PRESENT' END;
IF OBJECT_ID('cfg.DeployLog') IS NOT NULL
    EXEC sys.sp_executesql
         N'SELECT ScriptName, FileSha256, DeployedUtc FROM cfg.DeployLog ORDER BY ScriptName;';
'@

$raw = & python $runner -S $CentralServer -d $CentralDatabase -Q $q 2>&1
$rawText = ($raw | Out-String)
$logMissing = $rawText -match 'DEPLOYLOG_MISSING'

$logged = @{}
if (-not $logMissing) {
    foreach ($line in $raw) {
        if ($line -match '^\s{2}(\S+\.sql)\s+([0-9a-f]{64})\s+(.*)$') {
            $logged[$Matches[1]] = @{ Sha = $Matches[2]; When = $Matches[3].Trim() }
        }
    }
}

if ($logMissing) {
    Write-Host ''
    Write-Host 'cfg.DeployLog does not exist in this database yet.' -ForegroundColor Yellow
    Write-Host 'Every file below will therefore read as unverifiable - that is expected,' -ForegroundColor Yellow
    Write-Host 'not a fault. To start recording deployments:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host ("    python .\deploy\Invoke-EhdSql.py -S {0} -d {1} \" -f $CentralServer, $CentralDatabase) -ForegroundColor Gray
    Write-Host '        -i .\01-central\00-schemas-and-config.sql' -ForegroundColor Gray
    Write-Host ''
    Write-Host 'Each script registers itself the next time it is deployed through the runner.' -ForegroundColor Yellow
}
elseif ($logged.Count -eq 0) {
    Write-Host ''
    Write-Host 'cfg.DeployLog exists but has no entries yet.' -ForegroundColor Yellow
    Write-Host 'That is expected until each script is next deployed through the runner -' -ForegroundColor Yellow
    Write-Host 'it registers itself on a successful run. Deployments made with SSMS or' -ForegroundColor Yellow
    Write-Host 'sqlcmd are never recorded, which is why they cannot be verified.' -ForegroundColor Yellow
}

# --- what is on disk ---------------------------------------------------------
$files = Get-ChildItem -Path (Join-Path $root '01-central'),
                             (Join-Path $root '02-targets'),
                             (Join-Path $root '03-elasticjobs') -Filter *.sql |
         Sort-Object FullName

Write-Host ''
Write-Host 'Deployed-state check' -ForegroundColor Cyan
Write-Host ('  server   : {0}' -f $CentralServer)
Write-Host ('  database : {0}' -f $CentralDatabase)
Write-Host ''

$match = 0; $stale = 0; $unknown = 0
foreach ($f in $files) {
    $sha = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
    $rec = if ($logged.ContainsKey($f.Name)) { $logged[$f.Name] } else { $null }

    if ($null -eq $rec) {
        $unknown++
        Write-Host ('  [ ? ] {0,-30} never deployed through this tool' -f $f.Name) -ForegroundColor DarkYellow
    }
    elseif ($rec.Sha -eq $sha) {
        $match++
        Write-Host ('  [ OK ] {0,-29} matches, deployed {1}' -f $f.Name, $rec.When) -ForegroundColor Green
    }
    else {
        $stale++
        Write-Host ('  [STALE] {0,-28} DISK DIFFERS from what was deployed {1}' -f $f.Name, $rec.When) -ForegroundColor Red
        Write-Host ('         disk     {0}' -f $sha.Substring(0, 32)) -ForegroundColor Red
        Write-Host ('         deployed {0}' -f $rec.Sha.Substring(0, 32)) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('  {0} match, {1} stale, {2} unverifiable' -f $match, $stale, $unknown)
if ($stale) {
    Write-Host ''
    Write-Host '  Redeploy the STALE files:' -ForegroundColor Yellow
    Write-Host ("    python .\deploy\Invoke-EhdSql.py -S {0} -d {1} -i .\<path>" -f $CentralServer, $CentralDatabase)
}
if ($unknown -and -not $stale) {
    Write-Host ''
    Write-Host '  "Unverifiable" is not the same as "wrong" - it means the file was last' -ForegroundColor DarkYellow
    Write-Host '  deployed by something other than Invoke-EhdSql.py, so there is no record.' -ForegroundColor DarkYellow
}
Write-Host ''
exit ([int]($stale -gt 0))
