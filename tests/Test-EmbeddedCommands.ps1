<#
.SYNOPSIS
    Parses the T-SQL that is EMBEDDED inside Elastic Job step commands.

.DESCRIPTION
    Job step commands are stored as string literals (N'...') in the job
    definition scripts. Parsing the outer .sql file therefore proves nothing
    about the query that will actually run on a target - a syntax error inside
    a literal is invisible until the job fails in production, against a vendor
    database, at 3am.

    This script pulls every  SET @cmd = N'...';  assignment out of the job
    scripts, un-escapes the doubled quotes, and runs each through ScriptDom.

    It also enforces the read-only contract: any embedded command containing
    CREATE / ALTER / DROP / INSERT / UPDATE / DELETE / MERGE / SELECT INTO
    against a permanent object is reported, because those must never reach a
    monitored database.
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path $PSScriptRoot '..\03-elasticjobs'),
    [switch] $ShowCommands
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$dll = Get-ChildItem 'C:\Program Files\WindowsPowerShell\Modules\SqlServer' -Recurse `
        -Filter 'Microsoft.SqlServer.TransactSql.ScriptDom.dll' -ErrorAction SilentlyContinue |
        Where-Object FullName -notlike '*coreclr*' | Select-Object -First 1
if (-not $dll) { throw 'ScriptDom not found. Install the SqlServer PowerShell module.' }
Add-Type -Path $dll.FullName

$parser = New-Object Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser($true)

# Writes that are legitimate because they only touch session-scoped temp objects.
$TempOk = '(?i)\b(INTO|TABLE)\s+#'

$problems = 0
$checked  = 0
$skipped  = @()

# ---------------------------------------------------------------------------
# 25-jobs-setup.sql is the ONE job that is allowed to write to a target: it
# deploys the optional XE sessions and configures Query Store. It is exempt by
# name, and the exemption is REPORTED rather than silent - an invisible
# exemption would quietly erode the guarantee this test exists to provide.
# ---------------------------------------------------------------------------
$WriteAllowed = @('25-jobs-setup.sql')

Get-ChildItem -Path $Path -Filter '*.sql' -Recurse | Sort-Object Name | ForEach-Object {
    $file = $_

    if ($WriteAllowed -contains $file.Name) {
        $skipped += $file.Name
        return
    }

    $text = Get-Content $file.FullName -Raw

    # SET @cmd = N' ... ';   with '' as the escaped single quote
    $rx = [regex]"(?s)SET\s+@cmd\d*\s*=\s*N'((?:[^']|'')*)'\s*;"
    $m  = $rx.Matches($text)
    if (-not $m.Count) { return }

    Write-Host "`n$($file.Name)" -ForegroundColor Cyan

    # step names appear just after each command in an sp_add_jobstep call
    $stepNames = [regex]::Matches($text, "@step_name\s*=\s*N'([^']+)'") |
                 ForEach-Object { $_.Groups[1].Value }

    for ($i = 0; $i -lt $m.Count; $i++) {
        $checked++
        $inner = $m[$i].Groups[1].Value -replace "''", "'"
        $label = if ($i -lt $stepNames.Count) { $stepNames[$i] } else { "command $($i+1)" }

        # --- syntax -------------------------------------------------------
        $errs = $null
        $parser.Parse((New-Object System.IO.StringReader($inner)), [ref]$errs) | Out-Null

        if ($errs.Count) {
            $problems += $errs.Count
            Write-Host ("  [FAIL] {0}" -f $label) -ForegroundColor Red
            $errs | Select-Object -First 4 | ForEach-Object {
                Write-Host ("         line {0}: {1}" -f $_.Line, $_.Message) -ForegroundColor Red
            }
        }
        else {
            # --- read-only contract --------------------------------------
            # Scan the CODE only. Comments are prose and routinely contain words
            # like "into", "update" or "delete" - matching those produced a false
            # [WRITE] on a command that was perfectly read-only. Parsing above
            # still uses the original text, comments and all.
            $scan = $inner -replace '(?s)/\*.*?\*/', ' '      # block comments
            $scan = $scan  -replace '(?m)--[^\r\n]*',  ' '    # line comments

            $writes = @()
            foreach ($kw in 'CREATE','ALTER','DROP','TRUNCATE','INSERT','UPDATE','DELETE','MERGE','GRANT','REVOKE') {
                foreach ($hit in [regex]::Matches($scan, "(?im)^\s*$kw\b|\b$kw\s+(TABLE|INDEX|PROCEDURE|VIEW|SCHEMA|DATABASE)\b")) {
                    # allow temp-object DDL/DML
                    $ctx = $scan.Substring($hit.Index, [Math]::Min(80, $scan.Length - $hit.Index))
                    if ($ctx -notmatch $TempOk) { $writes += $kw }
                }
            }
            $intoPerm = [regex]::Matches($scan, '(?i)\bINTO\s+(?!#)[A-Za-z\[]')
            if ($intoPerm.Count) { $writes += 'SELECT INTO (permanent)' }

            if ($writes.Count) {
                $problems++
                Write-Host ("  [WRITE] {0} - contains: {1}" -f $label, (($writes | Select-Object -Unique) -join ', ')) -ForegroundColor Yellow
                Write-Host "          Embedded commands run INSIDE monitored databases and must be read-only." -ForegroundColor Yellow
            }
            else {
                Write-Host ("  [ OK ] {0,-18} {1,5} chars, read-only" -f $label, $inner.Length) -ForegroundColor Green
            }
        }

        if ($ShowCommands) { Write-Host $inner -ForegroundColor DarkGray }
    }
}

Write-Host ""
if ($skipped.Count) {
    Write-Host ("EXEMPT (write-capable by design): " + ($skipped -join ', ')) -ForegroundColor Yellow
    Write-Host "  That job deploys the optional XE sessions and Query Store. It is the only" -ForegroundColor DarkGray
    Write-Host "  job permitted to write to a target, and it is created disabled." -ForegroundColor DarkGray
}
if ($problems -eq 0) {
    Write-Host "$checked embedded command(s) checked - all parse and all are read-only." -ForegroundColor Green
    exit 0
}
Write-Host "$problems problem(s) across $checked embedded command(s)." -ForegroundColor Red
exit 1
