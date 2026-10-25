# Restore the DSH user environment from a tagged version of the local backup repo.
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Version,
    [switch]$List,
    [switch]$Force,
    [switch]$NoPurge,
    [switch]$SkipUserData,
    [switch]$SkipApiKey,
    [string]$ExtractTo,
    [string]$ProfileTarget = '',
    [string]$UserDataTarget = '',
    [string]$ApiKeyTarget = '',
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$config = Read-BackupConfig -Repo $repo
if ([string]::IsNullOrWhiteSpace($ProfileTarget)) { $ProfileTarget = $config.dshProfile }
if ([string]::IsNullOrWhiteSpace($UserDataTarget)) { $UserDataTarget = $config.userDataDir }
if ([string]::IsNullOrWhiteSpace($ApiKeyTarget)) { $ApiKeyTarget = $config.apiKeyDir }

function Test-TagPath {
    param([string]$Tag, [string]$Path)
    $found = @(& git -C $repo ls-tree -r --name-only $Tag -- $Path 2>$null)
    return ($found.Count -gt 0)
}

function Show-Versions {
    $tags = @(& git -C $repo tag --list 'v*' --sort=-creatordate 2>$null)
    if ($tags.Count -eq 0) {
        Write-Host 'No versions found. Run scripts\backup.ps1 first.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host 'Available versions:' -ForegroundColor Cyan
    foreach ($t in $tags) {
        $date = (& git -C $repo log -1 --format='%cd' --date='format:%Y-%m-%d %H:%M' $t 2>$null)
        $subject = (& git -C $repo log -1 --format='%s' $t 2>$null)
        Write-Host ('  {0,-24} {1}  {2}' -f $t, $date, $subject)
    }
    Write-Host ''
    Write-Host 'Version format: vYYMMDD.E.SSS (environment date . environment sequence . minor sequence)'
    Write-Host 'Restore:  powershell -ExecutionPolicy Bypass -File scripts\restore-version.ps1 <version> [-Force]'
    Write-Host 'Extract:  powershell -ExecutionPolicy Bypass -File scripts\restore-version.ps1 <version> -ExtractTo <folder>'
    Write-Host ''
}

if ($List -or [string]::IsNullOrWhiteSpace($Version)) {
    Show-Versions
    exit 0
}

if ($Version -match '^\d+$') { $Version = "v$Version" }
if ($Version -match '^\d{6}\.\d+\.\d{3,}$') { $Version = "v$Version" }
if ($Version -notmatch '^v\d{6}\.\d+\.\d{3,}$' -and $Version -notmatch '^v\d+$') {
    Write-Host "Invalid version '$Version'. Expected vYYMMDD.E.SSS (for example v261025.1.001)." -ForegroundColor Red
    exit 1
}

& git -C $repo rev-parse -q --verify "refs/tags/$Version^{commit}" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Version tag not found: $Version" -ForegroundColor Red
    Show-Versions
    exit 1
}

$tagVersionText = ''
if (Test-TagPath $Version 'version.txt') {
    $tagVersionText = ([string](& git -C $repo show "${Version}:version.txt" 2>$null)).Trim()
}
$tagInstallInfo = @()
if (Test-TagPath $Version 'mirror/metadata/install-identity/install-info.txt') {
    $tagInstallInfo = @(& git -C $repo show "${Version}:mirror/metadata/install-identity/install-info.txt" 2>$null)
}
$tagDshVersion = ''
foreach ($line in @($tagInstallInfo)) {
    if ($line -match '^FileVersion:\s*(.+)$') { $tagDshVersion = $Matches[1].Trim() }
}
$tagTime = (& git -C $repo log -1 --format='%cd' --date='format:%Y-%m-%d %H:%M:%S %z' $Version 2>$null)

Write-Host ''
Write-Host "Selected version : $Version (version.txt: $tagVersionText)" -ForegroundColor Cyan
Write-Host "Tag date         : $tagTime"
Write-Host "DSH version      : $(if ($tagDshVersion) { $tagDshVersion } else { 'unknown' })"
Write-Host ''

$tmpRoot = Join-Path $env:TEMP ('dsh-backup-restore-' + $Version + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Host "Checking out $Version to a temporary worktree..." -ForegroundColor Cyan
& git -C $repo worktree add --detach --quiet $tmpRoot $Version 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to check out $Version." -ForegroundColor Red
    exit 1
}

function Remove-TempWorktree {
    if ($KeepTemp) {
        Write-Host "Temporary worktree kept at: $tmpRoot" -ForegroundColor Yellow
        return
    }
    & git -C $repo worktree remove --force $tmpRoot 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
        & git -C $repo worktree prune 2>&1 | Out-Null
    }
}

try {
    $srcMirror = Join-Path $tmpRoot 'mirror'
    if (-not (Test-Path -LiteralPath (Join-Path $srcMirror 'profile'))) {
        throw "Checked-out version has no mirror\profile: $Version"
    }

    if ($ExtractTo) {
        $target = [System.IO.Path]::GetFullPath($ExtractTo)
        $protectedPaths = @($repo, $ProfileTarget, $UserDataTarget, $ApiKeyTarget, $config.dshInstallRoot) |
            Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($protectedPath in $protectedPaths) {
            if (Test-PathOverlap $target $protectedPath) {
                throw "Export directory must not overlap the backup repo, DSH profile, install root, APIKey, or user data: $protectedPath"
            }
        }
        Write-Host "Extracting $Version to: $target" -ForegroundColor Cyan
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
        $rc = Invoke-Robocopy -Source $srcMirror -Destination $target -NoMirror
        Write-Host "robocopy exit code: $rc"
        if ($rc -ge 8) { throw "Extract failed (robocopy exit $rc)." }
        Write-Host 'Extract finished. Live DSH data was not touched.' -ForegroundColor Green
        return
    }

    # --- Live restore requires DSH to be closed ------------------------------
    $running = @(Get-DshProcesses)
    if ($running.Count -gt 0) {
        $pids = ($running | ForEach-Object { $_.Id }) -join ', '
        if (-not $Force) {
            throw "DeepSeek Harness is running (PID: $pids). Close it first, or rerun with -Force."
        }
        Write-Host "Stopping DeepSeek Harness (PID: $pids)..." -ForegroundColor Yellow
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    $installed = Get-DshInstallInfo
    if ($installed -and $tagDshVersion -and $installed.FileVersion -ne $tagDshVersion) {
        Write-Host "WARNING: installed DSH is $($installed.FileVersion) but $Version was captured from $tagDshVersion." -ForegroundColor Yellow
        Write-Host '         Reinstall the matching DSH build first if you need a clean rollback.' -ForegroundColor Yellow
    }

    if (-not (Test-Path -LiteralPath (Split-Path -Parent $ProfileTarget))) {
        throw "Parent directory of profile target does not exist: $(Split-Path -Parent $ProfileTarget)"
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (Test-Path -LiteralPath $ProfileTarget) {
        $previous = "$ProfileTarget.pre-restore-$stamp"
        $i = 1
        while (Test-Path -LiteralPath $previous) { $previous = "$ProfileTarget.pre-restore-$stamp-$i"; $i++ }
        Write-Host "Moving current profile to: $previous" -ForegroundColor Yellow
        Move-Item -LiteralPath $ProfileTarget -Destination $previous
    }
    New-Item -ItemType Directory -Force -Path $ProfileTarget | Out-Null

    Write-Host "Restoring profile ($(if ($NoPurge) { 'merge' } else { 'mirror' }))..." -ForegroundColor Cyan
    $rc = Invoke-Robocopy -Source (Join-Path $srcMirror 'profile') -Destination $ProfileTarget -NoMirror:$NoPurge
    Write-Host "robocopy profile exit code: $rc"
    if ($rc -ge 8) { throw "Profile restore failed (robocopy exit $rc)." }

    if (-not $SkipUserData -and $UserDataTarget) {
        $udSrc = Join-Path $srcMirror 'extras\electron-userdata'
        if (Test-Path -LiteralPath $udSrc) {
            Write-Host 'Restoring Electron user data (merge, caches kept)...' -ForegroundColor Cyan
            New-Item -ItemType Directory -Force -Path $UserDataTarget | Out-Null
            $rc = Invoke-Robocopy -Source $udSrc -Destination $UserDataTarget -NoMirror
            Write-Host "robocopy electron-userdata exit code: $rc"
            if ($rc -ge 8) { Write-Host "WARN: user data restore incomplete (exit $rc)." -ForegroundColor Yellow }
        }
    }

    if (-not $SkipApiKey -and $ApiKeyTarget) {
        $keySrc = Join-Path $srcMirror 'extras\APIKey'
        if (Test-Path -LiteralPath $keySrc) {
            Write-Host 'Restoring APIKey folder (merge)...' -ForegroundColor Cyan
            New-Item -ItemType Directory -Force -Path $ApiKeyTarget | Out-Null
            $rc = Invoke-Robocopy -Source $keySrc -Destination $ApiKeyTarget -NoMirror
            Write-Host "robocopy APIKey exit code: $rc"
            if ($rc -ge 8) { Write-Host "WARN: APIKey restore incomplete (exit $rc)." -ForegroundColor Yellow }
        }
    }

    Write-Host ''
    Write-Host "Restored $Version." -ForegroundColor Green
    Write-Host 'Start DeepSeek Harness now. The next startup backup will record the restored'
    Write-Host 'state as a new incremental version, so nothing in the history is lost.'
    Write-Host ''
    Write-Host 'The previous profile was kept at:'
    if ($previous) { Write-Host "  $previous" -ForegroundColor Yellow }
    Write-Host 'Delete that folder once you are sure the rollback is good.'
}
catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
finally {
    Remove-TempWorktree
}
