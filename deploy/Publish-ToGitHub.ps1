<#
.SYNOPSIS
    Pushes this repository to GitHub using the Git Data API via the gh CLI.
    No git binary required.

.DESCRIPTION
    The obvious approach - the Contents API, one call per file - creates one
    COMMIT per file. For this repository that is roughly 45 commits of noise,
    and it is painful to undo if anything is wrong.

    This uses the Git Data API instead:
        1. create a blob for each file          -> blob SHAs
        2. create ONE tree from all the blobs   -> tree SHA
        3. create ONE commit pointing at it     -> commit SHA
        4. move refs/heads/<branch> to it

    The result is a single clean commit, exactly as a normal `git push` of an
    initial import would produce.

    Honours .gitignore-style exclusions through the -Exclude logic below. It
    does NOT parse .gitignore - the patterns are duplicated here deliberately,
    and the script PRINTS everything it is about to upload so you can check
    before anything leaves the machine.

.PARAMETER DryRun
    Default behaviour. Lists what would be uploaded and stops.

.EXAMPLE
    .\deploy\Publish-ToGitHub.ps1                       # dry run
    .\deploy\Publish-ToGitHub.ps1 -Confirm              # actually push
#>
[CmdletBinding()]
param(
    [string] $Owner  = 'Petar-T',
    [string] $Repo   = 'EnterpriseHealthDashboard',
    [string] $Branch = 'main',
    [string] $Message = 'Enterprise Health Dashboard: zero-footprint Azure SQL monitoring',
    [switch] $Confirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = 'C:\Program Files\GitHub CLI\gh.exe' }
if (-not (Test-Path $gh)) { throw 'GitHub CLI not found.' }

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

<#
    Write UTF-8 with NO byte-order mark.

    Set-Content -Encoding utf8 is not portable: on PowerShell 7 it writes plain
    UTF-8, but on Windows PowerShell 5.1 it PREPENDS a BOM (EF BB BF). GitHub's
    API then sees the BOM before the opening brace and rejects the whole request
    with

        gh: Problems parsing JSON (HTTP 400)

    which points at the payload rather than at the encoding, and only ever
    reproduces on 5.1. UTF8Encoding($false) writes the same bytes on both.
#>
function Write-Utf8NoBom {
    param([string] $Path, [string] $Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

try {
    # ----------------------------------------------------------------- checks
    Write-Host ''
    Write-Host "Target: $Owner/$Repo  (branch $Branch)" -ForegroundColor Cyan

    $perms = & $gh api "repos/$Owner/$Repo" --jq '.permissions.push' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Cannot read repos/$Owner/$Repo. Is the CLI signed in to an account that can see it?" }
    if ($perms -ne 'true') {
        Write-Host ''
        Write-Warning "The signed-in account has push = $perms on $Owner/$Repo."
        & $gh auth status 2>&1 | Select-String 'Logged in' | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
        Write-Host ''
        Write-Host '  Sign in as the repository owner first:' -ForegroundColor Yellow
        Write-Host '    gh auth login --hostname github.com --git-protocol https --web' -ForegroundColor Gray
        throw 'No push permission - nothing was uploaded.'
    }

    # ------------------------------------------------------------- file list
    # Mirrors .gitignore. Kept explicit rather than parsed, so that what is
    # published is reviewable in one place.
    $excludeFile = @(
        '*.old', '*.bak', '*.tmp', '~$*',
        '*.docx', '*.pdf',
        'estate*.html', '*-demo.html',
        'preview-*.png',
        'live-objects.txt',
        'secrets.json', '*.secret', '*.key', '*.pfx', '*.pem', '.env',
        '*.pyc'
    )
    $excludeDir = @('node_modules', '__pycache__', '.git', '.vscode', '.idea')

    $files = Get-ChildItem -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($root.Length + 1)
        $parts = $rel -split '\\'
        if ($parts | Where-Object { $excludeDir -contains $_ }) { return $false }
        foreach ($p in $excludeFile) { if ($_.Name -like $p) { return $false } }
        # the generated dashboards are excluded above; the TEMPLATE is required
        if ($_.Name -like '*.html' -and $_.Name -ne 'dashboard.html') { return $false }
        return $true
    } | Sort-Object FullName

    Write-Host ''
    Write-Host ("{0} file(s) to publish:" -f $files.Count) -ForegroundColor Cyan
    $files | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        "  {0,-58} {1,6} KB" -f $rel, [math]::Round($_.Length / 1KB, 1)
    }
    $totalKB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1KB, 0)
    Write-Host ("  total {0} KB" -f $totalKB)

    if (-not $Confirm) {
        Write-Host ''
        Write-Host 'DRY RUN - nothing was uploaded.' -ForegroundColor Yellow
        Write-Host 'Review the list above, then re-run with -Confirm.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    # ------------------------------------------------------------- 1. blobs
    Write-Host ''
    Write-Host 'Creating blobs...' -ForegroundColor Cyan
    $tree = @()
    $i = 0
    foreach ($f in $files) {
        $i++
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))

        $tmp = [IO.Path]::GetTempFileName()
        Write-Utf8NoBom $tmp (@{ content = $b64; encoding = 'base64' } | ConvertTo-Json -Compress)

        # --input with a FILE, not inline JSON: on Windows, inline JSON is
        # mangled by cmd.exe quoting rules.
        $sha = & $gh api "repos/$Owner/$Repo/git/blobs" --method POST --input $tmp --jq '.sha' 2>&1
        Remove-Item $tmp -Force

        if ($LASTEXITCODE -ne 0) { throw "blob failed for ${rel}: $sha" }
        $tree += @{ path = $rel; mode = '100644'; type = 'blob'; sha = "$sha".Trim() }
        Write-Host ("  [{0,3}/{1}] {2}" -f $i, $files.Count, $rel)
    }

    # -------------------------------------------------------------- 2. tree
    Write-Host ''
    Write-Host 'Creating tree...' -ForegroundColor Cyan
    $tmp = [IO.Path]::GetTempFileName()
    Write-Utf8NoBom $tmp (@{ tree = $tree } | ConvertTo-Json -Depth 5 -Compress)
    $treeSha = (& $gh api "repos/$Owner/$Repo/git/trees" --method POST --input $tmp --jq '.sha' 2>&1).Trim()
    Remove-Item $tmp -Force
    if ($LASTEXITCODE -ne 0) { throw "tree failed: $treeSha" }
    Write-Host "  tree $treeSha"

    # ------------------------------------------------------------ 3. commit
    # An empty repository has no parent commit. Detect rather than assume.
    $parent = & $gh api "repos/$Owner/$Repo/git/ref/heads/$Branch" --jq '.object.sha' 2>$null
    $hasParent = ($LASTEXITCODE -eq 0 -and $parent)

    $commitBody = @{ message = $Message; tree = $treeSha }
    if ($hasParent) { $commitBody.parents = @("$parent".Trim()) } else { $commitBody.parents = @() }

    $tmp = [IO.Path]::GetTempFileName()
    Write-Utf8NoBom $tmp ($commitBody | ConvertTo-Json -Depth 4 -Compress)
    $commitSha = (& $gh api "repos/$Owner/$Repo/git/commits" --method POST --input $tmp --jq '.sha' 2>&1).Trim()
    Remove-Item $tmp -Force
    if ($LASTEXITCODE -ne 0) { throw "commit failed: $commitSha" }
    Write-Host "  commit $commitSha"

    # --------------------------------------------------------------- 4. ref
    Write-Host ''
    Write-Host 'Updating branch...' -ForegroundColor Cyan
    $tmp = [IO.Path]::GetTempFileName()
    Write-Utf8NoBom $tmp (@{ sha = $commitSha; force = $false } | ConvertTo-Json -Compress)
    if ($hasParent) {
        $null = & $gh api "repos/$Owner/$Repo/git/refs/heads/$Branch" --method PATCH --input $tmp 2>&1
    } else {
        Remove-Item $tmp -Force
        $tmp = [IO.Path]::GetTempFileName()
        Write-Utf8NoBom $tmp (@{ ref = "refs/heads/$Branch"; sha = $commitSha } | ConvertTo-Json -Compress)
        $null = & $gh api "repos/$Owner/$Repo/git/refs" --method POST --input $tmp 2>&1
    }
    Remove-Item $tmp -Force
    if ($LASTEXITCODE -ne 0) { throw 'ref update failed' }

    Write-Host ''
    Write-Host '=================================================' -ForegroundColor Green
    Write-Host (" Published {0} file(s) in one commit" -f $files.Count) -ForegroundColor Green
    Write-Host (" https://github.com/{0}/{1}" -f $Owner, $Repo) -ForegroundColor Green
    Write-Host '=================================================' -ForegroundColor Green
}
finally { Pop-Location }
