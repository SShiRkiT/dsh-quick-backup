# Restore storage plugin caches from a complete pre-restore profile.
# These paths are intentionally excluded from the Git backup; this script does
# NOT run git add/commit and does NOT touch workspace.json or settings.
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param(
    [string]$SnapshotPath = '',
    [string]$ProfileTarget = '',
    [switch]$NoSafetyCopy
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Read-BackupConfig -Repo $repo
if ([string]::IsNullOrWhiteSpace($ProfileTarget)) { $ProfileTarget = $config.dshProfile }
if ([string]::IsNullOrWhiteSpace($ProfileTarget) -or -not (Test-Path -LiteralPath $ProfileTarget)) {
    throw "DSH profile not found: $ProfileTarget"
}

if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $parent = Split-Path -Parent $ProfileTarget
    $candidates = @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.dsh.pre-restore-*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        throw "No .dsh.pre-restore-* complete snapshot found next to $ProfileTarget. Pass -SnapshotPath explicitly."
    }
    $SnapshotPath = $candidates[0].FullName
}

$SnapshotPath = (Resolve-Path -LiteralPath $SnapshotPath).Path
if (Test-PathOverlap $SnapshotPath $ProfileTarget) {
    throw "SnapshotPath must be a separate directory, not the live profile: $SnapshotPath"
}
$sourceStorages = Join-Path $SnapshotPath 'storages'
if (-not (Test-Path -LiteralPath $sourceStorages)) {
    throw "Snapshot has no storages directory: $sourceStorages"
}

$liveStorages = Join-Path $ProfileTarget 'storages'
New-Item -ItemType Directory -Force -Path $liveStorages | Out-Null

$directoryNames = @('cost-meter', 'session_projcache')
$fileNames = @('session_projcache.json')
$found = @()
foreach ($name in $directoryNames) {
    if (Test-Path -LiteralPath (Join-Path $sourceStorages $name)) { $found += $name }
}
foreach ($name in $fileNames) {
    if (Test-Path -LiteralPath (Join-Path $sourceStorages $name)) { $found += $name }
}
if ($found.Count -eq 0) {
    throw "Snapshot has no restorable storage caches (cost-meter / session_projcache): $sourceStorages"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safetyRoot = Join-Path $repo "state\storage-restore-$stamp"
if (-not $NoSafetyCopy) {
    New-Item -ItemType Directory -Force -Path $safetyRoot | Out-Null
    foreach ($name in $found) {
        $livePath = Join-Path $liveStorages $name
        if (Test-Path -LiteralPath $livePath) {
            $target = Join-Path $safetyRoot $name
            if (Test-Path -LiteralPath $livePath -PathType Container) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                $rc = Invoke-Robocopy -Source $livePath -Destination $target -NoMirror
            } else {
                Copy-Item -LiteralPath $livePath -Destination $target -Force
                $rc = 0
            }
            if ($rc -ge 8) { Write-Warning "Safety copy incomplete for $name (robocopy exit $rc)." }
        }
    }
    Write-Host "Safety copy: $safetyRoot"
}

$running = @(Get-DshProcesses)
if ($running.Count -gt 0) {
    Write-Host 'WARN: DeepSeek Harness is currently running. Restart it after this restore.' -ForegroundColor Yellow
}

$beforeFiles = @(Get-ChildItem -LiteralPath $liveStorages -Recurse -File -Force -ErrorAction SilentlyContinue)
$beforeBytes = ($beforeFiles | Measure-Object Length -Sum).Sum

foreach ($name in $found) {
    $src = Join-Path $sourceStorages $name
    $dst = Join-Path $liveStorages $name
    if (Test-Path -LiteralPath $src -PathType Container) {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $rc = Invoke-Robocopy -Source $src -Destination $dst
        if ($rc -ge 8) { throw "Restore failed for $name (robocopy exit $rc)." }
    } else {
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    Write-Host "Restored: $name"
}

$afterFiles = @(Get-ChildItem -LiteralPath $liveStorages -Recurse -File -Force -ErrorAction SilentlyContinue)
$afterBytes = ($afterFiles | Measure-Object Length -Sum).Sum

Write-Host ''
Write-Host "Snapshot : $SnapshotPath"
Write-Host "Live     : $liveStorages"
Write-Host ("Files    : {0} -> {1}" -f $beforeFiles.Count, $afterFiles.Count)
Write-Host ("Bytes    : {0} -> {1}" -f $beforeBytes, $afterBytes)
Write-Host 'Restored : cost-meter, session_projcache, session_projcache.json (if present)'
Write-Host 'Skipped  : workspace.json, settings, plugins, credentials'
Write-Host 'Git      : no add/commit; these caches are excluded from backup history.'