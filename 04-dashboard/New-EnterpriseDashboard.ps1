<#
.SYNOPSIS
    Generates the Enterprise Health Dashboard from the central repository.

.DESCRIPTION
    This is the Edition 2 generator. The difference from Edition 1 is the whole
    point of the central design:

        Edition 1 (embedded) : open N connections, one per monitored database,
                               run ~20 queries against each, stitch the results
                               together client-side. Slow, fragile, and it fails
                               partially when any single database is unreachable.

        Edition 2 (central)  : open ONE connection to the repository and run one
                               batch. Every monitored database is already a row.
                               A target being down does not break generation -
                               it shows up as a CollectionState of CRITICAL.

    No target database is contacted by this script. It touches the central
    repository only, which matters when the targets are vendor-owned.

.PARAMETER CentralServer
    The logical server hosting the central repository,
    e.g. ehd-central.database.windows.net

.PARAMETER CentralDatabase
    The repository database name, e.g. EnterpriseHealth

.PARAMETER OutputPath
    Where to write the dashboard. Defaults to .\dashboard.html next to this
    script (overwriting the sample data in place).

.PARAMETER TemplatePath
    The HTML template. Defaults to dashboard.html next to this script. When
    OutputPath and TemplatePath are the same file, the template is read fully
    into memory first, so overwriting in place is safe.

.PARAMETER WindowHours
    Look-back window for the charts and top-N lists. Default 24.

.PARAMETER AccessToken
    Optional Entra ID access token. When omitted, the script uses
    Active Directory Default authentication (managed identity, Azure CLI,
    or an interactive browser prompt, in that order).

.PARAMETER ConnectionString
    Full connection string, overriding everything else. Use this for anything
    unusual - a non-default port, a named instance, or a token-auth scenario.

.PARAMETER IntegratedSecurity
    Connect with Windows authentication instead of Entra ID. Use this when the
    repository is hosted on SQL Server rather than Azure SQL Database - which
    is also how you can run the whole system locally, with no Azure at all.

.EXAMPLE
    .\New-EnterpriseDashboard.ps1 `
        -CentralServer   ehd-sql.database.windows.net `
        -CentralDatabase EnterpriseHealth

.EXAMPLE
    # dry run against a scratch SQL Server instance, before any Azure exists
    .\New-EnterpriseDashboard.ps1 -CentralServer <scratch-instance> `
        -CentralDatabase EHD_DryRun -IntegratedSecurity

.EXAMPLE
    # Scheduled refresh every 10 minutes using a managed identity
    .\New-EnterpriseDashboard.ps1 -CentralServer $s -CentralDatabase $d `
        -OutputPath \\fileshare\dashboards\estate.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CentralServer,
    [Parameter(Mandatory)][string] $CentralDatabase,
    [string] $OutputPath,
    [string] $TemplatePath,
    [int]    $WindowHours = 24,
    [string] $AccessToken,
    [string] $ConnectionString,
    [switch] $IntegratedSecurity,
    [int]    $QueryTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $TemplatePath) { $TemplatePath = Join-Path $here 'dashboard.html' }
if (-not $OutputPath)   { $OutputPath   = Join-Path $here 'dashboard.html' }

#------------------------------------------------------------------------------
# Make both paths ABSOLUTE before anything touches them.
#
# .NET file APIs - [System.IO.File]::WriteAllText among them - resolve relative
# paths against the PROCESS current directory, which in PowerShell is NOT the
# same as the shell's current location and is typically the user's home folder.
# A perfectly reasonable '-OutputPath .\04-dashboard\estate.html' therefore
# became 'C:\Users\<user>\04-dashboard\estate.html' and failed at the very last
# step, AFTER every query had already run. Resolve once, here, so the rest of
# the script cannot get this wrong.
#------------------------------------------------------------------------------
function Resolve-AbsolutePath {
    param([string] $PathValue)
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $PathValue))
}

$TemplatePath = Resolve-AbsolutePath $TemplatePath
$OutputPath   = Resolve-AbsolutePath $OutputPath

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    throw "Output directory does not exist: $outDir"
}

if (-not (Test-Path $TemplatePath)) {
    throw "Template not found: $TemplatePath"
}

#------------------------------------------------------------------------------
# Read the template FIRST. OutputPath and TemplatePath are the same file by
# default, so if generation failed halfway we would otherwise destroy the
# template and have nothing to regenerate from.
#
# READ WITH AN EXPLICIT ENCODING. This is not pedantry - omitting it silently
# corrupted every generated dashboard, and the damage COMPOUNDED on each run.
#
# Get-Content -Raw with no -Encoding uses the system ANSI code page on Windows
# PowerShell 5.1 (Windows-1252 on a Western install), while line 952 writes the
# result back as UTF-8. So a round trip mangles every non-ASCII character and
# makes it longer:
#
#     --  U+2014 EM DASH, UTF-8 bytes E2 80 94
#     read as CP1252 -> 'a-hat' + 'euro' + 'right-quote'  (3 chars)
#     written as UTF-8 -> 6 bytes ... and the next run re-reads THOSE as CP1252
#
# Measured on a 14-byte sample: 16 -> 21 -> 31 -> 51 bytes over three cycles.
# Because OutputPath defaults to this very file, the output becomes the next
# run's template and the corruption snowballs. The visible symptom was garbage
# either side of the database and server names in the two dropdowns - the only
# non-ASCII in the template is the em dash used as their separator.
#
# PowerShell 7 defaults Get-Content to UTF-8, so this never reproduced there -
# which is exactly why it survived testing. Reading through the .NET API with an
# explicit encoding is version-proof and symmetric with the write at the end.
# $TemplatePath is already absolute by this point, so the .NET path rule that
# bit us elsewhere does not apply.
#------------------------------------------------------------------------------
$template = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.Encoding]::UTF8)

$startMark = '/*__DATA_START__*/'
$endMark   = '/*__DATA_END__*/'
if ($template.IndexOf($startMark) -lt 0 -or $template.IndexOf($endMark) -lt 0) {
    throw "Template is missing the $startMark / $endMark markers. Use the shipped dashboard.html."
}

#------------------------------------------------------------------------------
# Connection. One, and only one.
#------------------------------------------------------------------------------
$useFallback = $false
try {
    Import-Module SqlServer -ErrorAction Stop
    # Importing is not enough - the module loads a NATIVE SNI library on first
    # use, and there is no build of it for every architecture (notably ARM64).
    # Probe it now so we fail over cleanly instead of dying mid-extract.
    Invoke-Sqlcmd -ServerInstance '.' -Query 'SELECT 1' -ConnectionTimeout 1 -ErrorAction Stop | Out-Null
}
catch {
    if ($_.Exception.Message -match 'SNI|TdsParser|Unable to load DLL') {
        Write-Warning "The SqlServer module cannot load its native client on this machine - falling back to System.Data.SqlClient."
        $useFallback = $true
    }
    # any other error here just means the probe server was unreachable, which is fine
}

# The message-matching above decides WHY we failed. This decides WHETHER we can
# proceed at all, and it is the check that actually matters.
#
# Pattern-matching the exception text only catches the architecture problem. Any
# other reason the module is unusable - not installed, blocked by execution
# policy, PSModulePath not covering the host, a half-finished install - produces
# a message that matches none of those patterns, so $useFallback stayed $false
# and the script sailed on to call a command that does not exist, dying later
# with the thoroughly unhelpful
#
#     The term 'Invoke-Sqlcmd' is not recognized as a name of a cmdlet
#
# which reads like a broken script rather than a missing module. Testing for the
# command itself is reason-agnostic: if we cannot call it, we use the fallback,
# which needs no module and ships with .NET.
if (-not $useFallback -and -not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Warning "The SqlServer module is not available here - falling back to System.Data.SqlClient. (Install-Module SqlServer -Scope CurrentUser to use it instead.)"
    $useFallback = $true
}

#------------------------------------------------------------------------------
# AUTHENTICATION
#
# A TOKEN is preferred over "Authentication=Active Directory Default", for both
# clients, for one reason: Active Directory Default makes the SQL client resolve
# credentials itself through Azure.Identity, and that dependency chain is
# frequently incomplete in practice. The observed failure is
#
#     AzureCliCredential authentication failed: Could not load file or assembly
#     'System.IO.Pipelines, Version=9.0.0.0'
#
# which is a PACKAGING problem in the client, not an authentication problem - and
# no amount of signing in differently will fix it. Fetching the token ourselves
# and handing it over sidesteps the entire credential stack. It is also exactly
# what deploy\Invoke-EhdSql.py does, which is why that works here when nothing
# else does.
#
# Precedence: -ConnectionString > -IntegratedSecurity > token > AD Default.
#------------------------------------------------------------------------------
if (-not $ConnectionString -and -not $IntegratedSecurity -and -not $AccessToken) {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Host "Acquiring an Entra token via the Azure CLI..." -ForegroundColor DarkGray
        $tok = & az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $tok) {
            $AccessToken = $tok.Trim()
        }
        else {
            Write-Warning "Azure CLI returned no token - falling back to Active Directory Default. Run 'az login' if the connection then fails."
        }
    }
}

if ($ConnectionString) {
    $cs = $ConnectionString
}
elseif ($IntegratedSecurity) {
    $cs = "Server=$CentralServer;Database=$CentralDatabase;Integrated Security=true;" +
          "TrustServerCertificate=true;Connect Timeout=30;"
}
elseif ($AccessToken) {
    # NO "Authentication=" keyword. The token is supplied out of band - on the
    # Invoke-Sqlcmd -AccessToken parameter, or on SqlConnection.AccessToken.
    # Leaving the keyword in would send the client back through Azure.Identity
    # and reintroduce the very failure we are avoiding. System.Data.SqlClient
    # cannot parse the keyword at all ("Keyword not supported: 'authentication'").
    $cs = "Server=tcp:$CentralServer,1433;Database=$CentralDatabase;" +
          "Encrypt=True;TrustServerCertificate=False;Connect Timeout=30;"
}
else {
    $cs = "Server=tcp:$CentralServer,1433;Database=$CentralDatabase;" +
          "Authentication=Active Directory Default;Encrypt=True;" +
          "TrustServerCertificate=False;Connect Timeout=30;"
}

$connArgs = @{
    ConnectionString = $cs
    QueryTimeout     = $QueryTimeoutSeconds
    ErrorAction      = 'Stop'
}
if ($AccessToken) { $connArgs['AccessToken'] = $AccessToken }

# Both clients now share one connection string; the token travels separately.
$csFallback = $cs

if ($useFallback -and -not $IntegratedSecurity -and -not $AccessToken) {
    throw ("This machine cannot load the SqlServer module's native client, so the script fell back to " +
           "System.Data.SqlClient - which has no interactive Entra flow. A token is required. Run " +
           "'az login', or pass one explicitly:`n`n" +
           "    `$t = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv`n" +
           "    .\New-EnterpriseDashboard.ps1 -CentralServer $CentralServer " +
           "-CentralDatabase $CentralDatabase -AccessToken `$t")
}

#------------------------------------------------------------------------------
# Invoke-Sqlcmd returns:
#     0 rows  -> $null          (NOT an empty array)
#     1 row   -> a single object (NOT an array of one)
#     n rows  -> an array
#
# Under Set-StrictMode, calling .Count on the $null case throws
# "The property 'Count' cannot be found on this object", which is a
# spectacularly misleading way to report "the query returned nothing".
# ,@($x) forces a single-element array wrapper that unrolls to a real array.
# This bug cost an hour in Edition 1 - do not remove the comma.
#------------------------------------------------------------------------------
function Invoke-Q {
    param([string]$Sql)

    if ($useFallback) {
        # System.Data.SqlClient is part of .NET itself and has no native
        # dependency, so it works where the SqlServer module cannot load.
        # Returns PSCustomObjects so the rest of the script is unchanged.
        $cn = New-Object System.Data.SqlClient.SqlConnection $csFallback
        # Token auth is set on the OBJECT, not in the connection string. Omitting
        # this was the bug that made -AccessToken silently do nothing on the
        # fallback path: the parameter only ever reached Invoke-Sqlcmd.
        if ($AccessToken) { $cn.AccessToken = $AccessToken }
        try {
            $cn.Open()
            $cmd = $cn.CreateCommand()
            $cmd.CommandText    = $Sql
            $cmd.CommandTimeout = $QueryTimeoutSeconds
            $rd = $cmd.ExecuteReader()
            $out = [System.Collections.ArrayList]::new()
            while ($rd.Read()) {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $rd.FieldCount; $i++) {
                    $v = $rd.GetValue($i)
                    $row[$rd.GetName($i)] = if ($v -is [System.DBNull]) { $null } else { $v }
                }
                [void]$out.Add([pscustomobject]$row)
            }
            $rd.Close()
            return ,@($out.ToArray())
        }
        finally { $cn.Close() }
    }

    $r = Invoke-Sqlcmd @connArgs -Query $Sql
    if ($null -eq $r) { return @() }
    return ,@($r)
}

function Get-Val {
    <# Safe property read - StrictMode makes $row.Missing throw. #>
    param($Row, [string]$Name, $Default = $null)
    if ($null -eq $Row) { return $Default }
    $p = $Row.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value -or $p.Value -is [System.DBNull]) { return $Default }
    return $p.Value
}

function N2 { param($v) if ($null -eq $v) { return 0 } return [math]::Round([double]$v, 2) }

Write-Host "Connecting to $CentralDatabase on $CentralServer ..." -ForegroundColor Cyan

#------------------------------------------------------------------------------
# Preflight: confirm the repository is actually deployed before running 20
# queries that would each fail with a confusing "Invalid object name".
#------------------------------------------------------------------------------
$preflight = Invoke-Q @"
SELECT HasCore    = CASE WHEN OBJECT_ID('core.vw_FleetScorecard') IS NOT NULL THEN 1 ELSE 0 END,
       HasTargets = ISNULL((SELECT COUNT(*) FROM cfg.Target WHERE IsEnabled = 1), 0),
       RepoRows   = ISNULL((SELECT SUM(p.rows) FROM sys.partitions p
                            JOIN sys.tables t  ON t.object_id = p.object_id
                            JOIN sys.schemas s ON s.schema_id = t.schema_id
                            WHERE s.name = 'core' AND p.index_id IN (0,1)), 0),
       RepoMB     = ISNULL((SELECT CAST(SUM(a.total_pages) * 8.0 / 1024 AS decimal(19,2))
                            FROM sys.allocation_units a
                            JOIN sys.partitions p ON p.partition_id = a.container_id
                            JOIN sys.tables t     ON t.object_id = p.object_id
                            JOIN sys.schemas s    ON s.schema_id = t.schema_id
                            WHERE s.name IN ('core','stg','cfg')), 0);
"@

if ($preflight.Count -eq 0 -or (Get-Val $preflight[0] 'HasCore' 0) -ne 1) {
    throw "core.vw_FleetScorecard not found in [$CentralDatabase]. Deploy 01-central\*.sql first."
}
$repoRows = [int64](Get-Val $preflight[0] 'RepoRows' 0)
$repoMB   = [double](Get-Val $preflight[0] 'RepoMB'   0)
$tgtCount = [int]   (Get-Val $preflight[0] 'HasTargets' 0)

if ($tgtCount -eq 0) {
    Write-Warning "cfg.Target has no enabled rows. The dashboard will be empty. Register targets first."
}

Write-Host ("  repository: {0:N0} rows, {1:N0} MB, {2} enabled target(s)" -f $repoRows, $repoMB, $tgtCount) -ForegroundColor DarkGray

#------------------------------------------------------------------------------
# THE PULL. Each query returns every database at once - that is the payoff.
#------------------------------------------------------------------------------
$W = $WindowHours

Write-Host "Reading fleet scorecard ..." -ForegroundColor Cyan
$fleet = Invoke-Q "SELECT * FROM core.vw_FleetScorecard ORDER BY ServerName, DatabaseName;"

if ($fleet.Count -eq 0) {
    Write-Warning "core.vw_FleetScorecard returned no rows. Nothing to render."
}

Write-Host "Reading alerts, waits, queries, blocking, errors, capacity, indexes, security ..." -ForegroundColor Cyan

$alerts = Invoke-Q @"
SELECT ServerName, DatabaseName, Severity, AlertCode, Category, Message, Detail,
       AgeMinutes = DATEDIFF(MINUTE, RaisedUtc, SYSUTCDATETIME())
FROM   core.vw_OpenAlerts ORDER BY CASE Severity WHEN 'Critical' THEN 0 WHEN 'Warning' THEN 1 ELSE 2 END, RaisedUtc DESC;
"@

$resHourly = Invoke-Q @"
SELECT ServerName, DatabaseName,
       H   = FORMAT(DATEADD(HOUR, DATEDIFF(HOUR, 0, EndTimeUtc), 0), 'HH:mm'),
       Ord = DATEADD(HOUR, DATEDIFF(HOUR, 0, EndTimeUtc), 0),
       Cpu = CAST(AVG(AvgCpuPct) AS decimal(9,2)),
       Io  = CAST(AVG(AvgDataIoPct) AS decimal(9,2)),
       Log = CAST(AVG(AvgLogWritePct) AS decimal(9,2)),
       Mem = CAST(AVG(AvgMemoryPct) AS decimal(9,2)),
       Wrk = CAST(MAX(MaxWorkerPct) AS decimal(9,2)),
       Ses = CAST(MAX(MaxSessionPct) AS decimal(9,2))
FROM   core.ResourceUsage
WHERE  EndTimeUtc >= DATEADD(HOUR, -$W, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, DATEADD(HOUR, DATEDIFF(HOUR, 0, EndTimeUtc), 0)
ORDER BY ServerName, DatabaseName, Ord;
"@

$waits = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY ResourceWaitSec DESC)
           FROM core.vw_TopWaits)
SELECT ServerName, DatabaseName, WaitType, ResourceWaitSec, WaitCount, AvgWaitMs, PctOfTotal, Interpretation
FROM   r WHERE rn <= 8 ORDER BY ServerName, DatabaseName, rn;
"@

$topQ = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY TotalCpuSec DESC)
           FROM core.vw_TopQueries)
SELECT ServerName, DatabaseName, QueryHash, ObjectName,
       Executions, TotalCpuSec, AvgCpuMs, AvgLogicalReads, PlanCount,
       SqlText = LEFT(ISNULL(SampleSqlText, N''), 400)
FROM   r WHERE rn <= 10 ORDER BY ServerName, DatabaseName, rn;
"@

$regress = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY CpuRegressionX DESC)
           FROM core.vw_QueryRegression)
SELECT ServerName, DatabaseName, QueryHash, ObjectName,
       BaseAvgCpuMs, CurAvgCpuMs, CpuRegressionX, BaseExecs, CurExecs,
       PlanCountChange, Verdict, SqlText = LEFT(ISNULL(SampleSql, N''), 400)
FROM   r WHERE rn <= 10 ORDER BY ServerName, DatabaseName, rn;
"@

$blocking = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY MaxWaitSec DESC)
           FROM core.vw_BlockingSummary)
SELECT ServerName, DatabaseName, HeadBlockerSessionId, Incidents, DistinctVictims, MaxWaitSec,
       MaxChainDepth, BlockerLogin, BlockerProgram, BlockerHost, BlockerStatus, WaitTypes,
       BlockerSql = LEFT(ISNULL(BlockerSql, N''), 400),
       VictimSql  = LEFT(ISNULL(SampleVictimSql, N''), 300)
FROM   r WHERE rn <= 10 ORDER BY ServerName, DatabaseName, rn;
"@

$errors = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY Occurrences DESC)
           FROM core.vw_ErrorSummary)
SELECT ServerName, DatabaseName, ErrorNumber, Severity, Occurrences, LastSeenUtc, TopApp,
       Message = LEFT(ISNULL(SampleMessage, N''), 300)
FROM   r WHERE rn <= 12 ORDER BY ServerName, DatabaseName, rn;
"@

$deadlocks = Invoke-Q @"
SELECT ServerName, DatabaseName, DayUtc, Deadlocks, MaxProcesses
FROM   core.vw_DeadlockSummary ORDER BY ServerName, DatabaseName, DayUtc;
"@

$capacity = Invoke-Q @"
SELECT ServerName, DatabaseName, CurrentUsedMB, MaxSizeMB, PctUsed, GrowthMBPerDay,
       DaysUntilFull, ProjectedFullUtc, Verdict, Confidence, SampleCount
FROM   core.vw_CapacityForecast;
"@

$spaceTrend = Invoke-Q @"
SELECT ServerName, DatabaseName, D = CAST(SnapshotUtc AS date),
       UsedMB = CAST(AVG(UsedMB) AS decimal(19,2))
FROM   core.DatabaseSpace
WHERE  SnapshotUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, CAST(SnapshotUtc AS date)
ORDER BY ServerName, DatabaseName, D;
"@

# The capacity tiles for log space, tempdb and index overhead come from three
# DIFFERENT tables than the forecast, each at its own cadence - so take the
# latest row per database from each rather than assuming a shared snapshot time.
# Without this the tiles render as "-%" while the data sits in the repository,
# which looks like missing collection rather than a missing join.
$spaceDetail = Invoke-Q @"
WITH sp AS (
    SELECT ServerName, DatabaseName, DataUsedMB, IndexUsedMB,
           rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY SnapshotUtc DESC)
    FROM   core.DatabaseSpace),
lg AS (
    SELECT ServerName, DatabaseName, UsedLogSpacePct, LogReuseWaitDesc,
           rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY SnapshotUtc DESC)
    FROM   core.LogSpace),
td AS (
    SELECT ServerName, DatabaseName, PctUsed,
           rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY SnapshotUtc DESC)
    FROM   core.TempDbUsage)
SELECT  sp.ServerName, sp.DatabaseName,
        DataMB    = sp.DataUsedMB,
        IndexMB   = sp.IndexUsedMB,
        LogPct    = lg.UsedLogSpacePct,
        LogReuse  = lg.LogReuseWaitDesc,
        TempdbPct = td.PctUsed
FROM    sp
LEFT JOIN lg ON lg.ServerName = sp.ServerName AND lg.DatabaseName = sp.DatabaseName AND lg.rn = 1
LEFT JOIN td ON td.ServerName = sp.ServerName AND td.DatabaseName = sp.DatabaseName AND td.rn = 1
WHERE   sp.rn = 1;
"@

$io = Invoke-Q @"
SELECT ServerName, DatabaseName, FileName, TypeDesc,
       ReadLatencyMs  = CAST(AVG(ReadLatencyMs)  AS decimal(9,2)),
       WriteLatencyMs = CAST(AVG(WriteLatencyMs) AS decimal(9,2)),
       ReadMBPerSec   = CAST(AVG(ReadMBPerSec)   AS decimal(9,2)),
       WriteMBPerSec  = CAST(AVG(WriteMBPerSec)  AS decimal(9,2))
FROM   core.vw_IoLatency
WHERE  SnapshotUtc >= DATEADD(HOUR, -$W, SYSUTCDATETIME())
GROUP BY ServerName, DatabaseName, FileName, TypeDesc
ORDER BY ServerName, DatabaseName, TypeDesc;
"@

$missing = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY ImpactScore DESC)
           FROM core.vw_MissingIndexTop)
SELECT ServerName, DatabaseName, SchemaName, TableName, EqualityColumns, InequalityColumns,
       IncludedColumns, UserSeeks, AvgUserImpact, ImpactScore, CreateStatement
FROM   r WHERE rn <= 10 ORDER BY ServerName, DatabaseName, rn;
"@

$unused = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY SizeMB DESC)
           FROM core.vw_UnusedIndexes WHERE Verdict LIKE 'DROP%' OR Verdict LIKE 'Unused%' OR Verdict LIKE 'Write-heavy%')
SELECT ServerName, DatabaseName, SchemaName, TableName, IndexName, SizeMB,
       TotalReads, UserUpdates, Verdict, DropStatement
FROM   r WHERE rn <= 10 ORDER BY ServerName, DatabaseName, rn;
"@

$frag = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY AvgFragmentationPct DESC)
           FROM core.vw_FragmentationWork)
SELECT ServerName, DatabaseName, SchemaName, TableName, IndexName,
       AvgFragmentationPct, PageCount, EstimatedSizeMB, RecommendedAction, MaintenanceStatement
FROM   r WHERE rn <= 12 ORDER BY ServerName, DatabaseName, rn;
"@

$tables = Invoke-Q @"
WITH latest AS (SELECT ServerName, DatabaseName, M = MAX(SnapshotDate) FROM core.TableSpace GROUP BY ServerName, DatabaseName),
     r AS (SELECT t.*, rn = ROW_NUMBER() OVER (PARTITION BY t.ServerName, t.DatabaseName ORDER BY t.TotalMB DESC)
           FROM core.TableSpace t JOIN latest l ON l.ServerName=t.ServerName AND l.DatabaseName=t.DatabaseName AND l.M=t.SnapshotDate)
SELECT ServerName, DatabaseName, SchemaName, TableName, RowCountEst, TotalMB, DataMB, IndexMB
FROM   r WHERE rn <= 12 ORDER BY ServerName, DatabaseName, rn;
"@

$drift = Invoke-Q @"
SELECT ServerName, DatabaseName, ChangeType, Severity, Subject, Detail, DetectedDate
FROM   core.vw_SecurityDrift ORDER BY ServerName, DatabaseName, DetectedDate DESC;
"@

$secErrors = Invoke-Q @"
WITH r AS (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY EventTimeUtc DESC)
           FROM core.ErrorEvent WHERE ErrorNumber IN (229, 230, 262, 297, 300, 916, 18456, 15247, 15151))
SELECT ServerName, DatabaseName, EventTimeUtc, ErrorNumber, LoginName, ProgramName, HostName,
       Message = LEFT(ISNULL(Message, N''), 300), SqlText = LEFT(ISNULL(SqlText, N''), 300)
FROM   r WHERE rn <= 20 ORDER BY ServerName, DatabaseName, rn;
"@

$feeds = Invoke-Q @"
SELECT f.ServerName, f.DatabaseName, f.FeedName, f.Tier, f.LastArrivalUtc, f.LastRowCount,
       AgeMin   = DATEDIFF(MINUTE, f.LastArrivalUtc, SYSUTCDATETIME()),
       LimitMin = CASE f.Tier WHEN 'Frequent' THEN cfg.fn_Int('Stale.FrequentMinutes', 20)
                              WHEN 'Standard' THEN cfg.fn_Int('Stale.StandardMinutes', 90)
                              ELSE cfg.fn_Int('Stale.DailyMinutes', 1560) END
FROM   core.FeedArrival AS f ORDER BY f.ServerName, f.DatabaseName, f.Tier, f.FeedName;
"@

#------------------------------------------------------------------------------
# Job health. This query is the single-database payoff: jobs.job_executions is
# in the same database as core.*, so a failure COUNT and the actual error TEXT
# come back on the same connection as everything else.
#
# When the two were separate databases this was impossible, and the dashboard's
# "Fails 24h" column was hard-coded to 0 - a control that looked live and never
# was.
#
# Guarded: core.vw_JobHealth only exists once 04-job-health.sql has run, and it
# returns nothing until the Elastic Job Agent exists.
#------------------------------------------------------------------------------
$jobHealth = @()
$hasJobHealth = Invoke-Q "SELECT Present = CASE WHEN OBJECT_ID('core.vw_JobHealth') IS NOT NULL THEN 1 ELSE 0 END;"
if ($hasJobHealth.Count -gt 0 -and (Get-Val $hasJobHealth[0] 'Present' 0) -eq 1) {
    $jobHealth = Invoke-Q @"
SELECT ServerName, DatabaseName, JobTier, Attempts24h, Failures24h, Successes24h,
       FailurePct, LastSuccessUtc, LastFailureUtc, LastError
FROM   core.vw_JobHealth;
"@
} else {
    Write-Warning "core.vw_JobHealth not found - run 01-central\04-job-health.sql. Job failure counts will show as 0."
}

$xe = Invoke-Q @"
WITH latest AS (SELECT ServerName, DatabaseName, SessionName, M = MAX(SnapshotUtc)
                FROM core.XeSessionHealth GROUP BY ServerName, DatabaseName, SessionName)
SELECT h.ServerName, h.DatabaseName, h.SessionName, h.State, h.DroppedEventCount,
       h.DroppedBufferCount, h.Verdict
FROM   core.XeSessionHealth h
JOIN   latest l ON l.ServerName=h.ServerName AND l.DatabaseName=h.DatabaseName
               AND l.SessionName=h.SessionName AND l.M=h.SnapshotUtc;
"@

#------------------------------------------------------------------------------
# Index everything by "server|database" so assembly is O(n) not O(n^2).
#------------------------------------------------------------------------------
function Group-ByTarget {
    param($Rows)
    $h = @{}
    foreach ($r in $Rows) {
        $k = "{0}|{1}" -f (Get-Val $r 'ServerName' ''), (Get-Val $r 'DatabaseName' '')
        if (-not $h.ContainsKey($k)) { $h[$k] = [System.Collections.ArrayList]::new() }
        [void]$h[$k].Add($r)
    }
    return $h
}
function Rows-For { param($Hash, [string]$Key) if ($Hash.ContainsKey($Key)) { return $Hash[$Key] } return @() }

$gAlerts=Group-ByTarget $alerts; $gRes=Group-ByTarget $resHourly; $gWait=Group-ByTarget $waits
$gTopQ=Group-ByTarget $topQ;     $gReg=Group-ByTarget $regress;   $gBlk=Group-ByTarget $blocking
$gErr=Group-ByTarget $errors;    $gDl=Group-ByTarget $deadlocks;  $gCap=Group-ByTarget $capacity
$gSd =Group-ByTarget $spaceDetail
$gSp=Group-ByTarget $spaceTrend; $gIo=Group-ByTarget $io;         $gMi=Group-ByTarget $missing
$gUi=Group-ByTarget $unused;     $gFr=Group-ByTarget $frag;       $gTb=Group-ByTarget $tables
$gDr=Group-ByTarget $drift;      $gSe=Group-ByTarget $secErrors;  $gFe=Group-ByTarget $feeds
$gXe=Group-ByTarget $xe;         $gJh=Group-ByTarget $jobHealth

#------------------------------------------------------------------------------
# Assemble the JSON contract. Identical shape to Edition 1, so the HTML and all
# of its rendering code is reused unchanged.
#------------------------------------------------------------------------------
$targets = [System.Collections.ArrayList]::new()
$neverReported = [System.Collections.ArrayList]::new()

foreach ($f in $fleet) {
    $srv = Get-Val $f 'ServerName' ''
    $db  = Get-Val $f 'DatabaseName' ''
    $key = "$srv|$db"

    #--------------------------------------------------------------------------
    # A target registered in cfg.Target that has NEVER delivered a row has no
    # data to render - every chart would be empty and every KPI zero, which
    # reads as "healthy" at a glance. It goes into meta.skipped instead, which
    # the dashboard turns into an explicit red callout.
    #
    # This is the Edition 2 equivalent of Edition 1's "unreachable" state. The
    # generator itself never fails to connect here - it only ever talks to the
    # central repository - so the failure is always the collection job, not us.
    #--------------------------------------------------------------------------
    $cs = [string](Get-Val $f 'CollectionState' 'OK')
    if ($cs -eq 'NEVER') {
        [void]$neverReported.Add([ordered]@{
            server   = $srv
            database = $db
            reason   = "Registered in cfg.Target but core.FeedArrival has no rows. " +
                       "Check that this database is in an EHD collection target group " +
                       "and that the job agent identity can connect to it."
        })
        continue
    }

    $cap = Rows-For $gCap $key | Select-Object -First 1
    $sd  = Rows-For $gSd  $key | Select-Object -First 1

    # Feed rows are per-feed; the dashboard shows per-TIER, so roll up to the
    # worst feed in each tier. A single dead feed must not be averaged away.
    $collectors = [System.Collections.ArrayList]::new()
    foreach ($tier in @('Frequent','Standard','Daily')) {
        $tierRows = @(Rows-For $gFe $key | Where-Object { (Get-Val $_ 'Tier' '') -eq $tier })

        # real failure data, from jobs.job_executions in this same database
        $jh = Rows-For $gJh $key | Where-Object { (Get-Val $_ 'JobTier' '') -eq $tier } | Select-Object -First 1
        $fails    = [int](Get-Val $jh 'Failures24h' 0)
        $attempts = [int](Get-Val $jh 'Attempts24h' 0)
        $lastErr  = [string](Get-Val $jh 'LastError' '')

        if ($tierRows.Count -eq 0) {
            # nothing has ever arrived for this tier - but the job may still be
            # running and failing, and that reason is the most useful thing we
            # can show.
            [void]$collectors.Add([ordered]@{
                tier = $tier; lastSuccess = $null; ageMin = 0
                failures24h = $fails; attempts24h = $attempts
                limitMin = 0; status = 'NEVER'; lastError = $lastErr })
            continue
        }
        $worst  = $tierRows | Sort-Object { [int](Get-Val $_ 'AgeMin' 0) } -Descending | Select-Object -First 1
        $age    = [int](Get-Val $worst 'AgeMin' 0)
        $limit  = [int](Get-Val $worst 'LimitMin' 0)
        $status = if ($age -gt ($limit * 3)) { 'CRITICAL' }
                  elseif ($age -gt $limit)   { 'WARNING' }
                  elseif ($fails -gt 0)      { 'WARNING' }   # current, but not reliably
                  else                       { 'OK' }
        $last = Get-Val $worst 'LastArrivalUtc' $null
        [void]$collectors.Add([ordered]@{
            tier        = $tier
            lastSuccess = if ($last) { ([datetime]$last).ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
            ageMin      = $age
            failures24h = $fails
            attempts24h = $attempts
            limitMin    = $limit
            status      = $status
            lastError   = $lastErr
        })
    }

    # Charts want parallel arrays of labels and values.
    $rh = @(Rows-For $gRes $key)
    $t = [ordered]@{
        id       = $key
        server   = $srv
        database = $db
        edition  = [string](Get-Val $f 'Edition' 'unknown')
        slo      = [string](Get-Val $f 'ServiceObjective' 'unknown')
        environment = [string](Get-Val $f 'Environment' '')
        owner       = [string](Get-Val $f 'Owner' '')
        vendorOwned = [bool](Get-Val $f 'IsVendorOwned' $false)

        kpi = [ordered]@{
            cpu        = N2 (Get-Val $f 'AvgCpuPct' 0)
            dataIo     = N2 (Get-Val $f 'AvgDataIoPct' 0)
            logWrite   = N2 (Get-Val $f 'AvgLogWritePct' 0)
            memory     = N2 (Get-Val $f 'AvgMemoryPct' 0)
            workers    = N2 (Get-Val $f 'PeakWorkerPct' 0)
            sessions   = N2 (Get-Val $f 'PeakSessionPct' 0)
            storagePct = N2 (Get-Val $f 'StoragePct' 0)
            healthScore   = [int](Get-Val $f 'HealthScore' 100)
            worstDimension= [string](Get-Val $f 'WorstDimension' 'No data')
            peakPercent   = N2 (Get-Val $f 'PeakPercent' 0)
        }

        alerts = @(Rows-For $gAlerts $key | ForEach-Object {
            [ordered]@{
                severity   = [string](Get-Val $_ 'Severity' 'Info')
                code       = [string](Get-Val $_ 'AlertCode' '')
                category   = [string](Get-Val $_ 'Category' '')
                message    = [string](Get-Val $_ 'Message' '')
                ageMinutes = [int](Get-Val $_ 'AgeMinutes' 0)
                detail     = [string](Get-Val $_ 'Detail' '')
            }})

        # The HTML reads ONE array of objects keyed h/cpu/io/log/mem/wrk - not
        # parallel arrays. Emitting the wrong shape here renders every chart and
        # sparkline silently blank, which sample data never exposed because the
        # sample used the correct shape. Keep this in step with lineChart() and
        # sparkline() in dashboard.html.
        resourceHourly = @($rh | ForEach-Object {
            [ordered]@{
                h   = [string](Get-Val $_ 'H' '')
                cpu = N2 (Get-Val $_ 'Cpu' 0)
                io  = N2 (Get-Val $_ 'Io'  0)
                log = N2 (Get-Val $_ 'Log' 0)
                mem = N2 (Get-Val $_ 'Mem' 0)
                wrk = N2 (Get-Val $_ 'Wrk' 0)
                ses = N2 (Get-Val $_ 'Ses' 0)
            }})

        waits = @(Rows-For $gWait $key | ForEach-Object {
            [ordered]@{
                type = [string](Get-Val $_ 'WaitType' '')
                sec  = N2 (Get-Val $_ 'ResourceWaitSec' 0)
                pct  = N2 (Get-Val $_ 'PctOfTotal' 0)
                count= [int64](Get-Val $_ 'WaitCount' 0)
                avgMs= N2 (Get-Val $_ 'AvgWaitMs' 0)
                note = [string](Get-Val $_ 'Interpretation' '')
            }})

        topQueries = @(Rows-For $gTopQ $key | ForEach-Object {
            [ordered]@{
                obj     = [string](Get-Val $_ 'ObjectName' '(ad hoc)')
                hash    = [string](Get-Val $_ 'QueryHash' '')
                execs   = [int64](Get-Val $_ 'Executions' 0)
                cpuSec  = N2 (Get-Val $_ 'TotalCpuSec' 0)
                avgMs   = N2 (Get-Val $_ 'AvgCpuMs' 0)
                reads   = N2 (Get-Val $_ 'AvgLogicalReads' 0)
                plans   = [int](Get-Val $_ 'PlanCount' 0)
                sql     = [string](Get-Val $_ 'SqlText' '')
            }})

        regressions = @(Rows-For $gReg $key | ForEach-Object {
            [ordered]@{
                obj       = [string](Get-Val $_ 'ObjectName' '(ad hoc)')
                hash      = [string](Get-Val $_ 'QueryHash' '')
                baseMs    = N2 (Get-Val $_ 'BaseAvgCpuMs' 0)
                curMs     = N2 (Get-Val $_ 'CurAvgCpuMs' 0)
                factor    = N2 (Get-Val $_ 'CpuRegressionX' 0)
                planDelta = [int](Get-Val $_ 'PlanCountChange' 0)
                verdict   = [string](Get-Val $_ 'Verdict' '')
                sql       = [string](Get-Val $_ 'SqlText' '')
            }})

        blocking = @(Rows-For $gBlk $key | ForEach-Object {
            [ordered]@{
                head      = [int](Get-Val $_ 'HeadBlockerSessionId' 0)
                incidents = [int](Get-Val $_ 'Incidents' 0)
                victims   = [int](Get-Val $_ 'DistinctVictims' 0)
                maxSec    = N2 (Get-Val $_ 'MaxWaitSec' 0)
                depth     = [int](Get-Val $_ 'MaxChainDepth' 0)
                login     = [string](Get-Val $_ 'BlockerLogin' '')
                app       = [string](Get-Val $_ 'BlockerProgram' '')
                host      = [string](Get-Val $_ 'BlockerHost' '')
                status    = [string](Get-Val $_ 'BlockerStatus' '')
                waitTypes = [string](Get-Val $_ 'WaitTypes' '')
                sql       = [string](Get-Val $_ 'BlockerSql' '')
                victimSql = [string](Get-Val $_ 'VictimSql' '')
            }})

        errors = @(Rows-For $gErr $key | ForEach-Object {
            [ordered]@{
                num   = [int](Get-Val $_ 'ErrorNumber' 0)
                sev   = [int](Get-Val $_ 'Severity' 0)
                count = [int](Get-Val $_ 'Occurrences' 0)
                last  = [string](Get-Val $_ 'LastSeenUtc' '')
                app   = [string](Get-Val $_ 'TopApp' '')
                msg   = [string](Get-Val $_ 'Message' '')
            }})

        deadlocks = @(Rows-For $gDl $key | ForEach-Object {
            [ordered]@{
                d = [string](Get-Val $_ 'DayUtc' '')
                n = [int](Get-Val $_ 'Deadlocks' 0)
            }})

        capacity = [ordered]@{
            usedMB   = N2 (Get-Val $cap 'CurrentUsedMB' (Get-Val $f 'UsedMB' 0))
            maxMB    = N2 (Get-Val $cap 'MaxSizeMB'     (Get-Val $f 'MaxSizeMB' 1))
            pctUsed  = N2 (Get-Val $cap 'PctUsed'       (Get-Val $f 'StoragePct' 0))
            growthPerDay  = N2 (Get-Val $cap 'GrowthMBPerDay' 0)
            daysUntilFull = if ($null -ne (Get-Val $cap 'DaysUntilFull' $null)) { [int](Get-Val $cap 'DaysUntilFull' 0) } else { $null }
            projectedFull = [string](Get-Val $cap 'ProjectedFullUtc' 'n/a')
            verdict       = [string](Get-Val $cap 'Verdict' 'Insufficient history')
            confidence    = [string](Get-Val $cap 'Confidence' 'Low')
            # consumed by the Log space / tempdb / Index overhead tiles
            logPct    = N2 (Get-Val $sd 'LogPct' 0)
            logReuse  = [string](Get-Val $sd 'LogReuse' '')
            tempdbPct = N2 (Get-Val $sd 'TempdbPct' 0)
            dataMB    = N2 (Get-Val $sd 'DataMB' 0)
            indexMB   = N2 (Get-Val $sd 'IndexMB' 0)
        }

        spaceTrend = @(Rows-For $gSp $key | ForEach-Object {
            [ordered]@{ d = [string](Get-Val $_ 'D' ''); mb = N2 (Get-Val $_ 'UsedMB' 0) }})

        io = @(Rows-For $gIo $key | ForEach-Object {
            [ordered]@{
                file = [string](Get-Val $_ 'FileName' '')
                type = [string](Get-Val $_ 'TypeDesc' '')
                readMs  = N2 (Get-Val $_ 'ReadLatencyMs' 0)
                writeMs = N2 (Get-Val $_ 'WriteLatencyMs' 0)
                readMB  = N2 (Get-Val $_ 'ReadMBPerSec' 0)
                writeMB = N2 (Get-Val $_ 'WriteMBPerSec' 0)
            }})

        missingIndexes = @(Rows-For $gMi $key | ForEach-Object {
            [ordered]@{
                schema = [string](Get-Val $_ 'SchemaName' 'dbo')
                table  = [string](Get-Val $_ 'TableName' '')
                eq     = [string](Get-Val $_ 'EqualityColumns' '')
                ineq   = [string](Get-Val $_ 'InequalityColumns' '')
                inc    = [string](Get-Val $_ 'IncludedColumns' '')
                seeks  = [int64](Get-Val $_ 'UserSeeks' 0)
                impact = N2 (Get-Val $_ 'AvgUserImpact' 0)
                score  = N2 (Get-Val $_ 'ImpactScore' 0)
                stmt   = [string](Get-Val $_ 'CreateStatement' '')
            }})

        unusedIndexes = @(Rows-For $gUi $key | ForEach-Object {
            [ordered]@{
                schema = [string](Get-Val $_ 'SchemaName' 'dbo')
                table  = [string](Get-Val $_ 'TableName' '')
                index  = [string](Get-Val $_ 'IndexName' '')
                sizeMB = N2 (Get-Val $_ 'SizeMB' 0)
                reads  = [int64](Get-Val $_ 'TotalReads' 0)
                updates= [int64](Get-Val $_ 'UserUpdates' 0)
                verdict= [string](Get-Val $_ 'Verdict' '')
                ddl    = [string](Get-Val $_ 'DropStatement' '')
            }})

        fragmentation = @(Rows-For $gFr $key | ForEach-Object {
            [ordered]@{
                schema = [string](Get-Val $_ 'SchemaName' 'dbo')
                table  = [string](Get-Val $_ 'TableName' '')
                index  = [string](Get-Val $_ 'IndexName' '')
                frag   = N2 (Get-Val $_ 'AvgFragmentationPct' 0)
                pages  = [int64](Get-Val $_ 'PageCount' 0)
                mb     = N2 (Get-Val $_ 'EstimatedSizeMB' 0)
                action = [string](Get-Val $_ 'RecommendedAction' '')
                ddl    = [string](Get-Val $_ 'MaintenanceStatement' '')
            }})

        tables = @(Rows-For $gTb $key | ForEach-Object {
            [ordered]@{
                schema  = [string](Get-Val $_ 'SchemaName' 'dbo')
                name    = [string](Get-Val $_ 'TableName' '')
                rows    = [int64](Get-Val $_ 'RowCountEst' 0)
                totalMB = N2 (Get-Val $_ 'TotalMB' 0)
                dataMB  = N2 (Get-Val $_ 'DataMB' 0)
                indexMB = N2 (Get-Val $_ 'IndexMB' 0)
            }})

        securityDrift = @(Rows-For $gDr $key | ForEach-Object {
            [ordered]@{
                type     = [string](Get-Val $_ 'ChangeType' '')
                severity = [string](Get-Val $_ 'Severity' '')
                subject  = [string](Get-Val $_ 'Subject' '')
                detail   = [string](Get-Val $_ 'Detail' '')
                date     = [string](Get-Val $_ 'DetectedDate' '')
            }})

        auditEvents = @(Rows-For $gSe $key | ForEach-Object {
            [ordered]@{
                utc    = [string](Get-Val $_ 'EventTimeUtc' '')
                action = "ERR " + [string](Get-Val $_ 'ErrorNumber' '')
                ok     = $false
                login  = [string](Get-Val $_ 'LoginName' '')
                target = [string](Get-Val $_ 'HostName' '')
                stmt   = [string](Get-Val $_ 'SqlText' '')
                ip     = ''
                app    = [string](Get-Val $_ 'ProgramName' '')
            }})

        auth = @()   # login auditing is a server-level control-plane feature, not collected here

        collectors = @($collectors)

        xe = @(Rows-For $gXe $key | ForEach-Object {
            [ordered]@{
                session = [string](Get-Val $_ 'SessionName' '')
                state   = [string](Get-Val $_ 'State' '')
                dropped = [int64](Get-Val $_ 'DroppedEventCount' 0)
                buffers = [int64](Get-Val $_ 'DroppedBufferCount' 0)
                verdict = [string](Get-Val $_ 'Verdict' '')
            }})
    }

    # A database that is reporting but STALE must still be visible, and must not
    # look healthy. Edition 1's bug was that such targets vanished entirely -
    # the single worst failure mode a monitoring dashboard can have.
    if ($cs -in @('CRITICAL','DISABLED')) {
        $t.kpi.worstDimension = 'NOT REPORTING'
        $t.kpi.healthScore    = 0
        if ($t.alerts.Count -eq 0) {
            $t.alerts = @([ordered]@{
                severity = 'Critical'; code = "COLLECTION_$cs"; category = 'Collection'
                message  = "Collection has stopped - state is $cs."
                ageMinutes = 0
                detail   = "Stale tiers: " + [string](Get-Val $f 'StaleTiers' '(unknown)') +
                           ". Every figure shown for this database is frozen at the last " +
                           "successful collection and must not be trusted."
            })
        }
    }

    [void]$targets.Add($t)
}

$payload = [ordered]@{
    isSample = $false
    meta = [ordered]@{
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        windowHours    = $WindowHours
        collectionRows = $repoRows
        repositoryMB   = $repoMB
        centralServer  = $CentralServer
        centralDatabase= $CentralDatabase
        skipped        = @($neverReported)   # registered targets that have never delivered a row
    }
    targets = @($targets)
}

$json = $payload | ConvertTo-Json -Depth 12 -Compress

#------------------------------------------------------------------------------
# Splice and write.
#------------------------------------------------------------------------------
$s = $template.IndexOf($startMark) + $startMark.Length
$e = $template.IndexOf($endMark)
if ($e -lt $s) { throw "Template markers are out of order - the file is corrupt." }

$out = $template.Substring(0, $s) + $json + $template.Substring($e)

$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

# UTF8 without BOM - a BOM before <!DOCTYPE> puts some browsers into quirks mode
[System.IO.File]::WriteAllText($OutputPath, $out, (New-Object System.Text.UTF8Encoding($false)))

$critical = ($targets | ForEach-Object { @($_.alerts | Where-Object { $_.severity -eq 'Critical' }).Count } | Measure-Object -Sum).Sum
$notReporting = @($targets | Where-Object { $_.kpi.worstDimension -eq 'NOT REPORTING' }).Count

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Green
Write-Host " Enterprise Health Dashboard generated" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Green
Write-Host ("  output          : {0}" -f $OutputPath)
Write-Host ("  databases       : {0}" -f $targets.Count)
Write-Host ("  servers         : {0}" -f (@($targets | ForEach-Object { $_.server } | Sort-Object -Unique)).Count)
Write-Host ("  critical alerts : {0}" -f $critical) -ForegroundColor $(if ($critical) { 'Red' } else { 'Green' })
Write-Host ("  stale           : {0}" -f $notReporting) -ForegroundColor $(if ($notReporting) { 'Red' } else { 'Green' })
Write-Host ("  never reported  : {0}" -f $neverReported.Count) -ForegroundColor $(if ($neverReported.Count) { 'Red' } else { 'Green' })
Write-Host ("  repository      : {0:N0} rows / {1:N0} MB" -f $repoRows, $repoMB)
Write-Host ("  payload         : {0:N0} KB" -f ($json.Length / 1KB))

if ($neverReported.Count) {
    Write-Host ""
    Write-Host " These targets are registered but have NEVER delivered data:" -ForegroundColor Yellow
    foreach ($n in $neverReported) { Write-Host ("   - {0} on {1}" -f $n.database, $n.server) -ForegroundColor Yellow }
    Write-Host " Why: SELECT * FROM core.vw_FeedDiagnosis ORDER BY Diagnosis;" -ForegroundColor DarkGray
}
Write-Host ""
