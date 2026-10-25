# Verify the local DSH backup repository (integrity, tags, working tree).
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param(
    [switch]$Deep
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

$problems = New-Object System.Collections.ArrayList
function Add-Problem([string]$text) { [void]$problems.Add($text); Write-Host ("  [FAIL] " + $text) -ForegroundColor Red }
function Add-Ok([string]$text) { Write-Host ("  [ OK ] " + $text) -ForegroundColor Green }

Write-Host ''
Write-Host "Verifying backup repository: $repo" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    Add-Problem 'Not a Git repository.'
    exit 1
}
Add-Ok 'Git repository found.'

$remotes = @(& git -C $repo remote 2>$null)
if ($remotes.Count -gt 0) {
    Add-Problem ('Remote configured: ' + ($remotes -join ', ') + ' (this repository must stay local-only).')
} else {
    Add-Ok 'No remote configured (local-only).'
}

$prePush = Join-Path $repo '.git\hooks\pre-push'
if (Test-Path -LiteralPath $prePush) {
    Add-Ok 'pre-push hook present (pushes blocked).'
} else {
    Add-Problem 'pre-push hook is missing; pushes are not blocked.'
}

$latest = Get-LatestTag -Repo $repo
if (-not $latest) {
    Add-Problem 'No version tags found.'
} else {
    Add-Ok "Latest version tag: $latest"
    if (-not (Parse-VersionName $latest)) {
        Add-Problem "Latest version '$latest' does not match vYYMMDD.E.SSS."
    } else {
        Add-Ok 'Version format is vYYMMDD.E.SSS.'
    }
    $versionText = (Read-TextFileUtf8 -Path (Join-Path $repo 'version.txt'))
    if ($versionText) { $versionText = $versionText.Trim() }
    if ($versionText -ne $latest) {
        Add-Problem "version.txt ($versionText) does not match latest tag ($latest)."
    } else {
        Add-Ok 'version.txt matches the latest tag.'
    }
    $diff = @(& git -C $repo diff --name-only $latest -- mirror 2>$null)
    if ($diff.Count -gt 0) {
        Add-Problem ("Working tree mirror differs from $latest in $($diff.Count) file(s). Run backup.ps1 or inspect with git status.")
    } else {
        Add-Ok "Working tree mirror matches $latest."
    }
}

$dirty = @(& git -C $repo status --porcelain 2>$null)
if ($dirty.Count -gt 0) {
    Add-Problem ('Working tree has uncommitted changes: ' + ($dirty.Count) + ' entr(ies).')
} else {
    Add-Ok 'Working tree is clean.'
}

$tagCount = @(& git -C $repo tag --list 'v*' 2>$null).Count
Write-Host ("  [INFO] Tags: $tagCount")

Write-Host '  [INFO] Checking Git object connectivity...'
& git -C $repo fsck --connectivity-only --no-progress 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Add-Problem 'git fsck reported problems.' } else { Add-Ok 'Git object connectivity OK.' }

if ($Deep) {
    Write-Host '  [INFO] Running full git fsck (may take a while)...'
    & git -C $repo fsck --full --no-progress 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Problem 'git fsck --full reported problems.' } else { Add-Ok 'Full object check OK.' }
}

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host 'Verification passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("Verification found $($problems.Count) problem(s).") -ForegroundColor Red
    exit 1
}
