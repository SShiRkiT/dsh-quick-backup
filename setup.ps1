# One-time setup for dsh-quick-backup.
# Creates a local-only backup repository and writes its config.
# The DSH plugin is installed separately from the repository address.
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param(
    [string]$RepoPath = '',
    [string]$DshProfile = '',
    [string]$InstallRoot = '',
    [string]$ApiKeyDir = '',
    [string]$UserDataDir = '',
    [switch]$SkipInitial,
    [switch]$IncludeCredentials,
    [switch]$EnableAutostart,
    [switch]$NoGlobalConfig,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Fail([string]$Text) { Write-Host "ERROR: $Text" -ForegroundColor Red; exit 1 }
function Test-PathOverlap([string]$A, [string]$B) {
    $a = [System.IO.Path]::GetFullPath($A).TrimEnd('\')
    $b = [System.IO.Path]::GetFullPath($B).TrimEnd('\')
    if ($a.Length -eq 2 -and $a[1] -eq ':') { $a += '\' }
    if ($b.Length -eq 2 -and $b[1] -eq ':') { $b += '\' }
    $a = $a.ToLowerInvariant(); $b = $b.ToLowerInvariant()
    return ($a -eq $b -or $a.StartsWith($b + '\') -or $b.StartsWith($a + '\'))
}

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    Fail 'RepoPath is required. Pass -RepoPath "D:\DSH-Backups" (there is no default backup path).'
}

$toolRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$repoFull = [System.IO.Path]::GetFullPath($RepoPath)
if (Test-PathOverlap $repoFull $toolRoot) {
    Fail "RepoPath must be a separate directory, not the tool repository or its parent/child: $repoFull"
}
$RepoPath = $repoFull

if (Test-Path -LiteralPath $RepoPath) {
    $entries = @(Get-ChildItem -LiteralPath $RepoPath -Force -ErrorAction SilentlyContinue)
    $marker = Join-Path $RepoPath '.dsh-quick-backup-data'
    if ($entries.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $marker)) {
            Fail "RepoPath exists and is not a dsh-quick-backup data repository: $RepoPath"
        }
        if (-not $Force) {
            Fail "RepoPath already exists; use -Force to reuse the existing data repository: $RepoPath"
        }
    }
} else {
    New-Item -ItemType Directory -Force -Path $RepoPath | Out-Null
}

if ($RepoPath -match '(?i)OneDrive|Dropbox|Google Drive|iCloud|Nutstore|Synology|NAS') {
    Write-Host 'WARN: the backup path looks like a cloud-sync or network location. The data repository contains plaintext credentials; do not sync or share it.' -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($DshProfile)) { $DshProfile = Get-DefaultDshProfile }
$DshProfile = Expand-EnvPath $DshProfile
if (-not (Test-Path -LiteralPath $DshProfile)) { Fail "DSH profile not found: $DshProfile" }

if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Find-DshInstallRoot }
$InstallRoot = Expand-EnvPath $InstallRoot
if ($InstallRoot -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot (Get-DshExeName)))) {
    Write-Host "WARN: DSH install root not found or invalid: $InstallRoot" -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($UserDataDir)) {
    $UserDataDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop'
}
$UserDataDir = Expand-EnvPath $UserDataDir

if ([string]::IsNullOrWhiteSpace($ApiKeyDir) -and $InstallRoot) {
    $candidate = Join-Path (Split-Path -Parent $InstallRoot) 'APIKey'
    if (Test-Path -LiteralPath $candidate) { $ApiKeyDir = $candidate }
}
$ApiKeyDir = Expand-EnvPath $ApiKeyDir

Write-Step 'Paths'
Write-Host "Backup repo : $RepoPath"
Write-Host "DSH profile : $DshProfile"
Write-Host "Install root: $(if ($InstallRoot) { $InstallRoot } else { '(not detected; metadata will be skipped)' })"
Write-Host "APIKey      : $(if ($ApiKeyDir) { $ApiKeyDir } else { '(not configured)' })"
Write-Host "User data   : $UserDataDir"
Write-Host "Credentials : $(if ($IncludeCredentials) { 'backed up' } else { 'excluded (default)' })"

Write-Step 'Copy workflow scripts'
$scriptTarget = Join-Path $RepoPath 'scripts'
New-Item -ItemType Directory -Force -Path $scriptTarget | Out-Null
$scriptNames = @('common.ps1', 'backup.ps1', 'restore-version.ps1', 'watch-dsh.ps1', 'install-autostart.ps1', 'uninstall-autostart.ps1', 'verify.ps1')
foreach ($name in $scriptNames) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "scripts\$name") -Destination (Join-Path $scriptTarget $name) -Force
}
Write-Host "Copied $($scriptNames.Count) scripts to $scriptTarget"

Write-Step 'Write config'
$config = [pscustomobject]@{
    schemaVersion       = 1
    dshProfile          = $DshProfile
    dshInstallRoot      = $InstallRoot
    apiKeyDir           = $ApiKeyDir
    userDataDir         = $UserDataDir
    includeCredentials  = [bool]$IncludeCredentials
    createdAt           = (Get-Date).ToString('o')
    generator           = 'dsh-quick-backup setup.ps1'
}
$configPath = Join-Path $RepoPath 'backup.config.json'
Write-TextFileUtf8 -Path $configPath -Text ($config | ConvertTo-Json -Depth 5)
Write-Host "Wrote $configPath"

$ignoreLines = @('/state/', '*.pre-restore-*', '/backup.config.json')
$ignorePath = Join-Path $RepoPath '.gitignore'
$existingIgnore = @()
if (Test-Path -LiteralPath $ignorePath) {
    $existingIgnore = @(Get-Content -LiteralPath $ignorePath -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
}
$mergedIgnore = @($existingIgnore)
foreach ($line in $ignoreLines) {
    if ($mergedIgnore -notcontains $line) { $mergedIgnore += $line }
}
[System.IO.File]::WriteAllLines($ignorePath, [string[]]$mergedIgnore, (New-Object System.Text.UTF8Encoding($false)))

$attributesPath = Join-Path $RepoPath '.gitattributes'
if (-not (Test-Path -LiteralPath $attributesPath)) {
    [System.IO.File]::WriteAllText($attributesPath, "* -text`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

$markerPath = Join-Path $RepoPath '.dsh-quick-backup-data'
$marker = [pscustomobject]@{
    schemaVersion = 1
    generator     = 'dsh-quick-backup setup.ps1'
    createdAt     = (Get-Date).ToString('o')
}
Write-TextFileUtf8 -Path $markerPath -Text ($marker | ConvertTo-Json -Depth 3)

Write-Step 'Initialize local Git repository'
Push-Location $RepoPath
try {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
        & git init -b main | Out-Null
    }
    & git config core.longpaths true
    & git config core.autocrlf false
    & git config core.quotepath false
    & git config push.default nothing
    if (-not (& git config user.name)) { & git config user.name 'DSH Quick Backup' }
    if (-not (& git config user.email)) { & git config user.email 'dsh-quick-backup@localhost' }
    $hookDir = Join-Path $RepoPath '.git\hooks'
    New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
    $hook = Join-Path $hookDir 'pre-push'
    if (-not (Test-Path -LiteralPath $hook)) {
        $hookText = "#!/bin/sh`necho 'ERROR: This backup repository is local-only. Pushing is disabled.' >&2`nexit 1`n"
        [System.IO.File]::WriteAllText($hook, $hookText, (New-Object System.Text.UTF8Encoding($false)))
    }
} finally {
    Pop-Location
}

if (-not $SkipInitial -and -not (Test-Path -LiteralPath (Join-Path $RepoPath 'version.txt'))) {
    Write-Step 'Create initial baseline (this can take a while)'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoPath 'scripts\backup.ps1') -Trigger setup -Baseline -Force
    if ($LASTEXITCODE -ne 0) { Fail "Initial baseline failed (exit $LASTEXITCODE)" }
} elseif (Test-Path -LiteralPath (Join-Path $RepoPath 'version.txt')) {
    Write-Host 'Existing version.txt found; skipped initial baseline.'
} else {
    Write-Host 'Skipped initial baseline (-SkipInitial).'
}

Write-Step 'Register plugin discovery config'
$globalConfigPath = if ($NoGlobalConfig) { '' } else { Get-GlobalConfigPath }
if ($globalConfigPath) {
    $globalDir = Split-Path -Parent $globalConfigPath
    New-Item -ItemType Directory -Force -Path $globalDir | Out-Null
    $globalCfg = [pscustomobject]@{
        schemaVersion  = 1
        repo           = $RepoPath
        dshProfile     = $DshProfile
        dshInstallRoot = $InstallRoot
    }
    Write-TextFileUtf8 -Path $globalConfigPath -Text ($globalCfg | ConvertTo-Json -Depth 5)
    Write-Host "Wrote $globalConfigPath"
}

if ($EnableAutostart) {
    Write-Step 'Enable automatic backup at DSH start'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoPath 'scripts\install-autostart.ps1') -StartNow
}

Write-Step 'Done'
Write-Host 'Backup repository : ' -NoNewline; Write-Host $RepoPath -ForegroundColor Green
Write-Host 'Config            : ' -NoNewline; Write-Host $configPath -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '1. Install the plugin from DSH Settings -> Plugins by entering this repository address:'
Write-Host '   https://github.com/SShiRkiT/dsh-quick-backup'
Write-Host '2. Restart DSH and open Settings -> Backup.'
Write-Host "3. The path should be prefilled with: $RepoPath"
Write-Host '   If not, paste it into "Backup repository path" and save.'
Write-Host ''
Write-Host 'The data repository is local-only. Never upload it or put it in a cloud-sync folder.'
