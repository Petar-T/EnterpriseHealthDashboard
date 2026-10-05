<#
.SYNOPSIS
    Asserts that cfg.Setting and the code agree about every configuration key.

.DESCRIPTION
    This system is tuned by UPDATE statements against cfg.Setting. That only
    works if the key you update is the key the code reads. Two failure modes,
    both silent:

      READ BUT NOT DEFINED
        Code calls cfg.fn_Int('Alert.CpuWarnPct', 75). The row does not exist,
        so the function returns the hard-coded 75 forever. Your
        UPDATE cfg.Setting ... WHERE SettingKey = 'Alert.CpuWarnPct'
        matches ZERO rows and reports success. The threshold never changes and
        nothing anywhere says so.

      DEFINED BUT NEVER READ
        cfg.Setting contains Alert.CpuPct. Nothing reads it. Somebody tunes it,
        watches for an hour, and concludes the alerting is broken.

    The first of these shipped in an early build of this edition: all 21 alert
    thresholds AND both Staging.*Column keys were read but never defined, which
    would have made the documented fix for a staging mismatch a no-op.

    This test parses the SQL directly - no database connection needed - so it
    can run before deployment and in CI.

.EXAMPLE
    .\Test-SettingKeys.ps1

.EXAMPLE
    .\Test-SettingKeys.ps1 -Quiet   # exit code only, for CI
#>
[CmdletBinding()]
param(
    [string] $Root,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

$configFile = Join-Path $Root '01-central\00-schemas-and-config.sql'
if (-not (Test-Path $configFile)) { throw "Config file not found: $configFile" }

#------------------------------------------------------------------------------
# Keys the code READS.
#   cfg.fn_Int('Key', default) / cfg.fn_Dec(...) / cfg.fn_Str(...)
#   SELECT SettingValue FROM cfg.Setting WHERE SettingKey = 'Key'
#------------------------------------------------------------------------------
$read = @{}
$sqlFiles = Get-ChildItem $Root -Recurse -Filter *.sql -File

foreach ($f in $sqlFiles) {
    $text = Get-Content $f.FullName -Raw

    foreach ($m in [regex]::Matches($text, "cfg\.fn_(?:Int|Dec|Str)\s*\(\s*'([^']+)'")) {
        $k = $m.Groups[1].Value
        if (-not $read.ContainsKey($k)) { $read[$k] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$read[$k].Add($f.Name)
    }
    foreach ($m in [regex]::Matches($text, "SettingKey\s*=\s*'([^']+)'")) {
        $k = $m.Groups[1].Value
        if (-not $read.ContainsKey($k)) { $read[$k] = [System.Collections.Generic.HashSet[string]]::new() }
        [void]$read[$k].Add($f.Name)
    }
}

#------------------------------------------------------------------------------
# Keys the config file DEFINES, minus any the config file explicitly deletes.
#------------------------------------------------------------------------------
$configText = Get-Content $configFile -Raw

$defined = [System.Collections.Generic.HashSet[string]]::new()
foreach ($m in [regex]::Matches($configText, "\(\s*'([A-Za-z]+\.[A-Za-z0-9]+)'\s*,\s*N'")) {
    [void]$defined.Add($m.Groups[1].Value)
}

# the obsolete-key cleanup block lists keys that are intentionally removed
$deleted = [System.Collections.Generic.HashSet[string]]::new()
$delBlock = [regex]::Match($configText, "(?s)DELETE FROM cfg\.Setting\s*WHERE SettingKey IN\s*\((.*?)\);")
if ($delBlock.Success) {
    foreach ($m in [regex]::Matches($delBlock.Groups[1].Value, "'([^']+)'")) {
        [void]$deleted.Add($m.Groups[1].Value)
    }
}

#------------------------------------------------------------------------------
# Compare. The DELETE block is not a definition, so a key that appears in both
# the VALUES list and the DELETE list is a contradiction worth reporting.
#------------------------------------------------------------------------------
$readNotDefined = @($read.Keys | Where-Object { -not $defined.Contains($_) } | Sort-Object)
$definedNotRead = @($defined   | Where-Object { -not $read.ContainsKey($_) } | Sort-Object)
$contradictory  = @($defined   | Where-Object { $deleted.Contains($_) }      | Sort-Object)

$fail = $readNotDefined.Count + $definedNotRead.Count + $contradictory.Count

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Setting key reconciliation" -ForegroundColor Cyan
    Write-Host ("  scanned {0} SQL file(s)" -f $sqlFiles.Count) -ForegroundColor DarkGray
    Write-Host ("  keys read by code : {0}" -f $read.Count)
    Write-Host ("  keys defined      : {0}" -f $defined.Count)
    Write-Host ("  keys retired      : {0}" -f $deleted.Count)
    Write-Host ""

    if ($readNotDefined.Count) {
        Write-Host "  READ BUT NOT DEFINED - tuning these does nothing:" -ForegroundColor Red
        foreach ($k in $readNotDefined) {
            Write-Host ("    {0,-32} read by {1}" -f $k, (($read[$k] | Sort-Object) -join ', ')) -ForegroundColor Red
        }
        Write-Host ""
    }
    if ($definedNotRead.Count) {
        Write-Host "  DEFINED BUT NEVER READ - dead config, remove or wire up:" -ForegroundColor Yellow
        foreach ($k in $definedNotRead) { Write-Host ("    {0}" -f $k) -ForegroundColor Yellow }
        Write-Host ""
    }
    if ($contradictory.Count) {
        Write-Host "  DEFINED AND DELETED in the same script - the DELETE wins:" -ForegroundColor Red
        foreach ($k in $contradictory) { Write-Host ("    {0}" -f $k) -ForegroundColor Red }
        Write-Host ""
    }

    if ($fail -eq 0) {
        Write-Host ("  OK - all {0} key(s) read by code are defined, and nothing is dead." -f $read.Count) -ForegroundColor Green
    } else {
        Write-Host ("  {0} problem(s) found." -f $fail) -ForegroundColor Red
    }
    Write-Host ""
}

exit $(if ($fail -eq 0) { 0 } else { 1 })
