# Incremental backup of the DSH user environment into a local Git archive.
# Intended to run hidden at every DeepSeek Harness start (see watch-dsh.ps1).
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param(
    [ValidateSet('startup', 'manual', 'logon', 'recovery', 'test', 'setup')]
    [string]$Trigger = 'manual',
    [switch]$Force,
    [switch]$Baseline,
    [int]$MinIntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$config = Read-BackupConfig -Repo $repo

$started = Get-Date
$stateDir = Join-Path $repo 'state'
$versionDir = Join-Path $stateDir 'versions'
$logDir = Join-Path $stateDir 'logs'
foreach ($d in @($stateDir, $versionDir, $logDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

function Write-LastRun {
    param(
        [string]$Status,
        [string]$Version = '',
        [string]$Commit = '',
        [string]$Message = '',
        [int]$Added = 0,
        [int]$Modified = 0,
        [int]$Deleted = 0
    )
    $now = Get-Date
    $obj = [pscustomobject]@{
        finishedAt      = $now.ToString('o')
        status          = $Status
        version         = $Version
        commit          = $Commit
        trigger         = $Trigger
        durationSeconds = [math]::Round(($now - $started).TotalSeconds, 1)
        added           = $Added
        modified        = $Modified
        deleted         = $Deleted
        message         = $Message
    }
    $path = Join-Path $stateDir 'last-run.json'
    Write-TextFileUtf8 -Path $path -Text ($obj | ConvertTo-Json -Depth 5)
}

function Invoke-Backup {
    Write-BackupLog -Repo $repo -Message ("Backup start (trigger=$Trigger, force=$Force)")

    # --- Basic preconditions -------------------------------------------------
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        throw "Not a Git repository: $repo"
    }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git.exe was not found on PATH.'
    }

    $profileSrc = $config.dshProfile
    if (-not (Test-Path -LiteralPath $profileSrc)) {
        throw "DSH profile directory is missing: $profileSrc (set dshProfile in backup.config.json)"
    }

    $mirror = Join-Path $repo 'mirror'
    $profileDst = Join-Path $mirror 'profile'
    foreach ($d in @($mirror, $profileDst)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    # Keep the repository cheap to scan and diff.
    & git -C $repo config core.longpaths true
    & git -C $repo config core.autocrlf false
    & git -C $repo config core.quotepath false

    # --- Min interval guard (watcher can fire more than once) ----------------
    if (-not $Force) {
        $lastRunPath = Join-Path $stateDir 'last-run.json'
        if (Test-Path -LiteralPath $lastRunPath) {
            try {
                $lastRun = Get-Content -LiteralPath $lastRunPath -Raw | ConvertFrom-Json
                if ($lastRun -and $lastRun.finishedAt -and $lastRun.status -eq 'ok') {
                    $elapsed = ([datetimeoffset]::Now - [datetimeoffset]::Parse($lastRun.finishedAt)).TotalSeconds
                    if ($elapsed -lt $MinIntervalSeconds) {
                        Write-BackupLog -Repo $repo -Message ("Skipped: last successful run was {0:N0}s ago (min interval {1}s)." -f $elapsed, $MinIntervalSeconds)
                        return 0
                    }
                }
            } catch { }
        }
    }

    # --- Sync profile --------------------------------------------------------
    # Caches / derived state are intentionally NOT backed up: they change on
    # every app start and would create meaningless versions.
    $excludeProfileDirs = Get-ProfileExcludeDirs -ProfileSrc $profileSrc
    $excludeFiles = Get-ProfileExcludeFiles -ProfileSrc $profileSrc
    if (-not $config.includeCredentials) {
        $excludeFiles += (Join-Path $profileSrc '.credentials.yaml')
    }

    Write-BackupLog -Repo $repo -Message 'Syncing profile (robocopy /MIR)...'
    $rc = Invoke-Robocopy -Source $profileSrc -Destination $profileDst -ExcludeDirs $excludeProfileDirs -ExcludeFiles $excludeFiles
    Write-BackupLog -Repo $repo -Message ("robocopy profile exit code: $rc")
    if ($rc -ge 8) {
        throw "robocopy failed for the profile directory (exit $rc)."
    }

    # --- Sync Electron user data --------------------------------------------
    $udSrc = $config.userDataDir
    $udDst = Join-Path $mirror 'extras\electron-userdata'
    if ($udSrc -and (Test-Path -LiteralPath $udSrc)) {
        $excludeUdDirs = Get-UserDataExcludeDirs -UserDataSrc $udSrc
        $excludeUdFiles = Get-UserDataExcludeFiles
        $rc = Invoke-Robocopy -Source $udSrc -Destination $udDst -ExcludeDirs $excludeUdDirs -ExcludeFiles $excludeUdFiles
        Write-BackupLog -Repo $repo -Message ("robocopy electron-userdata exit code: $rc")
        if ($rc -ge 8) {
            Write-BackupLog -Repo $repo -Message ("WARN: electron user data copy incomplete (exit $rc); continuing.") -Level WARN
        }
    } else {
        Write-BackupLog -Repo $repo -Message "WARN: electron user data not found: $udSrc" -Level WARN
    }

    # Robocopy does not always purge excluded directories from an existing
    # destination; remove them explicitly so they also leave Git tracking.
    $cachePaths = Get-MirrorCachePaths -ProfileDst $profileDst -UserDataDst $udDst
    foreach ($cachePath in $cachePaths) {
        if (Test-Path -LiteralPath $cachePath) {
            Remove-Item -LiteralPath $cachePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $config.includeCredentials) {
        $credentialMirror = Join-Path $profileDst '.credentials.yaml'
        if (Test-Path -LiteralPath $credentialMirror) {
            Remove-Item -LiteralPath $credentialMirror -Force -ErrorAction SilentlyContinue
        }
        $apiMirror = Join-Path $mirror 'extras\APIKey'
        if (Test-Path -LiteralPath $apiMirror) {
            Remove-Item -LiteralPath $apiMirror -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Sync APIKey folder --------------------------------------------------
    $apiSrc = $config.apiKeyDir
    $apiDst = Join-Path $mirror 'extras\APIKey'
    if ($config.includeCredentials -and $apiSrc -and (Test-Path -LiteralPath $apiSrc)) {
        $rc = Invoke-Robocopy -Source $apiSrc -Destination $apiDst
        Write-BackupLog -Repo $repo -Message ("robocopy APIKey exit code: $rc")
        if ($rc -ge 8) {
            Write-BackupLog -Repo $repo -Message ("WARN: APIKey copy incomplete (exit $rc); continuing.") -Level WARN
        }
    } elseif (-not $config.includeCredentials) {
        Write-BackupLog -Repo $repo -Message 'APIKey backup disabled (includeCredentials=false); skipped.' -Level INFO
    } elseif ($apiSrc) {
        Write-BackupLog -Repo $repo -Message "WARN: APIKey folder not found: $apiSrc" -Level WARN
    } else {
        Write-BackupLog -Repo $repo -Message 'APIKey folder not configured; skipped.' -Level INFO
    }

    # --- Install identity metadata ------------------------------------------
    $installRoot = $config.dshInstallRoot
    $info = Get-DshInstallInfo -InstallRoot $installRoot
    $metaDir = Join-Path $mirror 'metadata\install-identity'
    if (-not (Test-Path -LiteralPath $metaDir)) { New-Item -ItemType Directory -Force -Path $metaDir | Out-Null }

    $dshVersion = ''
    if ($info) {
        $dshVersion = [string]$info.FileVersion
        $infoText = @(
            "ExeName: $($info.ExeName)",
            "FileVersion: $($info.FileVersion)",
            "ProductVersion: $($info.ProductVersion)",
            "FileWriteTime: $($info.WriteTime.ToString('o'))"
        ) -join "`r`n"
        Write-TextFileUtf8 -Path (Join-Path $metaDir 'install-info.txt') -Text $infoText

        $updateYml = Join-Path $installRoot 'resources\app-update.yml'
        if (Test-Path -LiteralPath $updateYml) {
            Copy-Item -LiteralPath $updateYml -Destination (Join-Path $metaDir 'app-update.yml') -Force
        }

        # Hash the 174 MB app.asar only when it changed (cache in state/).
        $asar = Join-Path $installRoot 'resources\app.asar'
        if (Test-Path -LiteralPath $asar) {
            $asarItem = Get-Item -LiteralPath $asar
            $cachePath = Join-Path $stateDir 'app-asar.cache.json'
            $hash = $null
            $cacheValid = $false
            if (Test-Path -LiteralPath $cachePath) {
                try {
                    $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
                    if ($cache.sha256 -and $cache.length -eq $asarItem.Length -and
                        $cache.lastWriteUtc -eq $asarItem.LastWriteTimeUtc.ToString('o')) {
                        $hash = [string]$cache.sha256
                        $cacheValid = $true
                    }
                } catch { }
            }
            if (-not $cacheValid) {
                Write-BackupLog -Repo $repo -Message 'Hashing app.asar (first run or app updated)...'
                $hash = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash.ToLowerInvariant()
                $cacheObj = [pscustomobject]@{
                    sha256       = $hash
                    length       = $asarItem.Length
                    lastWriteUtc = $asarItem.LastWriteTimeUtc.ToString('o')
                }
                Write-TextFileUtf8 -Path $cachePath -Text ($cacheObj | ConvertTo-Json)
            }
            Write-TextFileUtf8 -Path (Join-Path $metaDir 'app.asar.sha256') -Text ("app.asar SHA256: $hash")
        }
    } else {
        Write-BackupLog -Repo $repo -Message "WARN: DSH executable not found under $installRoot" -Level WARN
    }

    # --- Stage ---------------------------------------------------------------
    Write-BackupLog -Repo $repo -Message 'Staging changes with git add -A ...'
    $addOut = & git -C $repo add -A -- . 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git add failed: " + ($addOut -join ' '))
    }

    $staged = @(& git -C $repo diff --cached --name-status --no-renames 2>$null | Where-Object { $_ -and $_.Trim() })
    if ($staged.Count -eq 0) {
        Write-BackupLog -Repo $repo -Message 'No changes detected; no new version created.'
        Write-LastRun -Status 'unchanged' -Version ([string](Get-LatestTag -Repo $repo)) -Message 'no changes'
        return 0
    }

    # --- Summarize -----------------------------------------------------------
    $added = 0
    $modified = 0
    $deleted = 0
    $changedPaths = New-Object System.Collections.ArrayList
    $sessionSet = New-Object 'System.Collections.Generic.HashSet[string]'
    $pluginSet = New-Object 'System.Collections.Generic.HashSet[string]'
    $pluginManifests = @(
        'mirror/profile/profiles/desktop/package.json',
        'mirror/profile/profiles/desktop/cordis.patch.yml',
        'mirror/profile/profiles/desktop/pnpm-lock.yaml',
        'mirror/profile/profiles/desktop/pnpm-workspace.yaml'
    )

    foreach ($line in $staged) {
        $tab = $line.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $status = $line.Substring(0, $tab).Trim()
        $path = $line.Substring($tab + 1).Trim()
        [void]$changedPaths.Add($path)

        switch ($status.Substring(0, 1)) {
            'A' { $added++ }
            'M' { $modified++ }
            'D' { $deleted++ }
            default { $modified++ }
        }

        if ($status.StartsWith('A') -and $path -match '^mirror/profile/sessions/([^/]+)/([^/]+)/') {
            [void]$sessionSet.Add($Matches[1] + '/' + $Matches[2])
        }
        if ($pluginManifests -contains $path) {
            [void]$pluginSet.Add((Split-Path -Leaf $path))
        }
    }

    # --- Version number, version.txt, VERSIONS.md ---------------------------
    $now = Get-Date
    $timeText = $now.ToString('yyyy-MM-dd HH:mm:ss zzz')
    $mirrorPaths = @($changedPaths | Where-Object { $_ -like 'mirror/*' })
    $currentVersion = Get-CurrentVersion -Repo $repo

    if ($Baseline) {
        if ($currentVersion) { throw "Baseline requested but version.txt already exists: $currentVersion" }
        $isMajor = $false
        $kind = 'baseline'
        $version = 'v' + $now.ToString('yyMMdd') + '.1.001'
    } else {
        $isMajor = Test-MajorChange -Paths $mirrorPaths
        $kind = if ($isMajor) { 'major' } else { 'minor' }
        $version = Get-NextVersionName -Current $currentVersion -IsMajor $isMajor -Now $now
        while (@(& git -C $repo tag --list $version 2>$null).Count -gt 0) {
            $version = Get-NextVersionName -Current $version -IsMajor $isMajor -Now $now
        }
    }
    $parts = Parse-VersionName $version
    Write-TextFileUtf8 -Path (Join-Path $repo 'version.txt') -Text $version

    $entry = [pscustomobject]@{
        version    = $version
        kind       = $kind
        envDate    = if ($parts) { $parts.Date.ToString('000000') } else { '' }
        envSeq     = if ($parts) { $parts.Env } else { 0 }
        minorSeq   = if ($parts) { $parts.Minor } else { 0 }
        time       = $timeText
        trigger    = $Trigger
        added      = $added
        modified   = $modified
        deleted    = $deleted
        sessions   = @($sessionSet | Sort-Object)
        plugins    = @($pluginSet | Sort-Object)
        dshVersion = $dshVersion
        note       = if ($kind -eq 'baseline') { 'full tree under date-based versioning' } else { '' }
    }

    $known = @(Get-VersionStateEntries -Repo $repo)
    if (-not ($known | Where-Object { $_.version -eq $version })) {
        $known = @($known) + $entry
    }
    Update-VersionIndex -Repo $repo -Entries $known

    & git -C $repo add -- version.txt VERSIONS.md 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git add failed for version.txt / VERSIONS.md' }

    # --- Commit + tag --------------------------------------------------------
    $subject = "$version | $timeText | $kind | $Trigger | +$added ~$modified -$deleted"
    $bodyParts = New-Object System.Collections.ArrayList
    [void]$bodyParts.Add('DSH incremental backup')
    [void]$bodyParts.Add('')
    [void]$bodyParts.Add("Version : $version ($kind)")
    [void]$bodyParts.Add("Baseline: v$($entry.envDate).$($entry.envSeq)")
    [void]$bodyParts.Add("Trigger : $Trigger")
    [void]$bodyParts.Add("Time    : $timeText")
    [void]$bodyParts.Add("Changes : +$added ~$modified -$deleted (tracked files)")
    [void]$bodyParts.Add("Sessions added: $($sessionSet.Count)")
    $pluginText = if ($pluginSet.Count) { ($pluginSet | Sort-Object) -join ', ' } else { 'none' }
    [void]$bodyParts.Add("Plugin manifests: $pluginText")
    [void]$bodyParts.Add("Credentials: $(if ($config.includeCredentials) { 'backed up' } else { 'excluded' })")
    [void]$bodyParts.Add("DSH version: $(if ($dshVersion) { $dshVersion } else { 'unknown' })")
    $bodyLines = $bodyParts -join "`n"

    Write-BackupLog -Repo $repo -Message ("Committing $version ($kind) ...")
    $commitOut = & git -C $repo -c commit.gpgsign=false commit -m $subject -m $bodyLines 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git commit failed: " + ($commitOut -join ' '))
    }

    $tagOut = & git -C $repo -c tag.gpgsign=false tag -a $version -m $subject 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git tag failed: " + ($tagOut -join ' '))
    }

    $commitHash = (& git -C $repo rev-parse HEAD).Trim()

    # --- Persist per-version metadata (not tracked) -------------------------
    $entryJson = [pscustomobject]@{
        version      = $version
        kind         = $kind
        envDate      = $entry.envDate
        envSeq       = $entry.envSeq
        minorSeq     = $entry.minorSeq
        time         = $timeText
        trigger      = $Trigger
        commit       = $commitHash
        subject      = $subject
        added        = $added
        modified     = $modified
        deleted      = $deleted
        sessions     = @($sessionSet | Sort-Object)
        plugins      = @($pluginSet | Sort-Object)
        dshVersion   = $dshVersion
        durationSec  = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    }
    Write-TextFileUtf8 -Path (Join-Path $versionDir "$version.json") -Text ($entryJson | ConvertTo-Json -Depth 8)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines((Join-Path $versionDir "$version.changes.txt"), [string[]]$staged, $utf8)

    Write-LastRun -Status 'ok' -Version $version -Commit $commitHash -Message 'committed' -Added $added -Modified $modified -Deleted $deleted
    Write-BackupLog -Repo $repo -Message ("Created $version ($kind, $commitHash) +$added ~$modified -$deleted in {0:N1}s" -f ((Get-Date) - $started).TotalSeconds)

    $dirty = @(& git -C $repo status --porcelain 2>$null)
    if ($dirty.Count -gt 0) {
        Write-BackupLog -Repo $repo -Message ("WARN: working tree still dirty after commit: " + ($dirty -join ' | ')) -Level WARN
    }
    return 0
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\DSH-AutoBackup')
$locked = $false
$code = 0
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) {
        Write-BackupLog -Repo $repo -Message 'Another backup run is active; skipping.'
        $code = 0
    } else {
        $code = Invoke-Backup
    }
} catch {
    $msg = $_.Exception.Message
    Write-BackupLog -Repo $repo -Message ("Backup failed: $msg") -Level ERROR
    try { Write-LastRun -Status 'error' -Message $msg } catch { }
    $code = 1
} finally {
    if ($locked) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
}
exit $code
