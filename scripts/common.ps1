# Shared helpers for the DSH incremental backup repository.
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

# Prefer the standalone Git for Windows install over any bundled git that may
# appear on PATH (for example one shipped inside a DSH plugin runtime).
$systemGitCmd = Join-Path $env:ProgramFiles 'Git\cmd'
if (Test-Path -LiteralPath (Join-Path $systemGitCmd 'git.exe')) {
    $env:PATH = $systemGitCmd + ';' + $env:PATH
}

# The shipped executable name uses a normal space. Keep it in one place.
function Get-DshProcessName {
    return 'DeepSeek Harness'
}

function Get-DshExeName {
    return ((Get-DshProcessName) + '.exe')
}

function Get-DshProcesses {
    $name = Get-DshProcessName
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq $name })
}

function Expand-EnvPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-DefaultDshProfile {
    return (Join-Path $env:USERPROFILE '.dsh')
}

function Find-DshInstallRoot {
    param([string]$Hint = '')
    $exeName = Get-DshExeName
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $candidate = Expand-EnvPath $Hint
        if (Test-Path -LiteralPath (Join-Path $candidate $exeName)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $proc = Get-DshProcesses | Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { return (Split-Path -Parent $proc.Path) }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\@deepseek-ai\dsh-desktop'),
        (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') (Get-DshProcessName)),
        (Join-Path $env:ProgramFiles (Get-DshProcessName))
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate $exeName))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return ''
}

function Read-BackupConfig {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $path = Join-Path $Repo 'backup.config.json'
    $raw = $null
    if (Test-Path -LiteralPath $path) {
        try { $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $raw = $null }
    }

    $profile = if ($raw -and $raw.dshProfile) { $raw.dshProfile } else { Get-DefaultDshProfile }
    $installRoot = if ($raw -and $raw.dshInstallRoot) { $raw.dshInstallRoot } else { Find-DshInstallRoot }
    $apiKeyDir = if ($raw -and $raw.apiKeyDir) { $raw.apiKeyDir } else { '' }
    if ([string]::IsNullOrWhiteSpace($apiKeyDir) -and $installRoot) {
        $candidate = Join-Path (Split-Path -Parent $installRoot) 'APIKey'
        if (Test-Path -LiteralPath $candidate) { $apiKeyDir = $candidate }
    }
    $userDataDir = if ($raw -and $raw.userDataDir) { $raw.userDataDir } else {
        Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop'
    }
    $includeCredentials = $true
    if ($raw -and $raw.PSObject.Properties['includeCredentials']) {
        $includeCredentials = [bool]$raw.includeCredentials
    }

    return [pscustomobject]@{
        dshProfile         = Expand-EnvPath $profile
        dshInstallRoot     = Expand-EnvPath $installRoot
        apiKeyDir          = Expand-EnvPath $apiKeyDir
        userDataDir        = Expand-EnvPath $userDataDir
        includeCredentials = $includeCredentials
    }
}

function Test-PathOverlap {
    param([string]$PathA, [string]$PathB)
    $a = [System.IO.Path]::GetFullPath($PathA).TrimEnd('\')
    $b = [System.IO.Path]::GetFullPath($PathB).TrimEnd('\')
    if ($a.Length -eq 2 -and $a[1] -eq ':') { $a += '\' }
    if ($b.Length -eq 2 -and $b[1] -eq ':') { $b += '\' }
    $a = $a.ToLowerInvariant()
    $b = $b.ToLowerInvariant()
    return ($a -eq $b -or $a.StartsWith($b + '\') -or $b.StartsWith($a + '\'))
}

function Get-GlobalConfigPath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return '' }
    return (Join-Path $env:LOCALAPPDATA 'dsh-quick-backup\config.json')
}

function Write-BackupLog {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $logDir = Join-Path $Repo 'state\logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $logPath = Join-Path $logDir 'backup.log'
    if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 8MB)) {
        Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force
    }
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @(),
        [switch]$NoMirror
    )
    $a = @(
        $Source, $Destination,
        '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:1', '/MT:16', '/XJ',
        '/NFL', '/NDL', '/NP', '/NJH', '/NJS'
    )
    if ($NoMirror) { $a += '/E' } else { $a += '/MIR' }
    if ($ExcludeDirs.Count -gt 0) { $a += '/XD'; $a += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $a += '/XF'; $a += $ExcludeFiles }
    & robocopy @a 2>&1 | Out-Null
    return [int]$LASTEXITCODE
}

function Get-ProfileExcludeDirs {
    param([string]$ProfileSrc)
    return @(
        (Join-Path $ProfileSrc 'profiles\node_modules'),
        (Join-Path $ProfileSrc 'cache'),
        (Join-Path $ProfileSrc 'logs'),
        (Join-Path $ProfileSrc 'storages\session_projcache'),
        (Join-Path $ProfileSrc 'storages\cost-meter'),
        (Join-Path $ProfileSrc 'studymate\reach')
    )
}

function Get-ProfileExcludeFiles {
    param([string]$ProfileSrc)
    return @(
        (Join-Path $ProfileSrc 'storages\session_projcache.json'),
        '*.tmp', '*.pid', 'Thumbs.db', 'desktop.ini', '.DS_Store'
    )
}

function Get-UserDataExcludeDirs {
    param([string]$UserDataSrc)
    return @(
        (Join-Path $UserDataSrc 'Cache'),
        (Join-Path $UserDataSrc 'Code Cache'),
        (Join-Path $UserDataSrc 'GPUCache'),
        (Join-Path $UserDataSrc 'GPUPersistentCache'),
        (Join-Path $UserDataSrc 'GrShaderCache'),
        (Join-Path $UserDataSrc 'ShaderCache'),
        (Join-Path $UserDataSrc 'DawnGraphiteCache'),
        (Join-Path $UserDataSrc 'DawnWebGPUCache'),
        (Join-Path $UserDataSrc 'Crashpad'),
        (Join-Path $UserDataSrc 'logs'),
        (Join-Path $UserDataSrc 'Local Storage'),
        (Join-Path $UserDataSrc 'Session Storage'),
        (Join-Path $UserDataSrc 'Network'),
        (Join-Path $UserDataSrc 'Shared Dictionary'),
        (Join-Path $UserDataSrc 'blob_storage'),
        (Join-Path $UserDataSrc 'WebStorage')
    )
}

function Get-UserDataExcludeFiles {
    return @(
        'Cookies', 'Cookies-journal', '*.tmp', '*.lock', 'LOCK', 'lockfile',
        'LOG', 'LOG.old', 'DIPS', 'DIPS-wal', 'DIPS-shm',
        'declarative_performance_observer.db', 'declarative_performance_observer.db-journal',
        'background-close-confirmed', 'Preferences'
    )
}

function Get-MirrorCachePaths {
    param(
        [string]$ProfileDst,
        [string]$UserDataDst
    )
    return @(
        (Join-Path $ProfileDst 'storages\session_projcache'),
        (Join-Path $ProfileDst 'storages\session_projcache.json'),
        (Join-Path $ProfileDst 'storages\cost-meter'),
        (Join-Path $ProfileDst 'studymate\reach'),
        (Join-Path $ProfileDst 'cache'),
        (Join-Path $ProfileDst 'logs'),
        (Join-Path $UserDataDst 'Cache'),
        (Join-Path $UserDataDst 'Code Cache'),
        (Join-Path $UserDataDst 'GPUCache'),
        (Join-Path $UserDataDst 'GPUPersistentCache'),
        (Join-Path $UserDataDst 'GrShaderCache'),
        (Join-Path $UserDataDst 'ShaderCache'),
        (Join-Path $UserDataDst 'DawnGraphiteCache'),
        (Join-Path $UserDataDst 'DawnWebGPUCache'),
        (Join-Path $UserDataDst 'Crashpad'),
        (Join-Path $UserDataDst 'logs'),
        (Join-Path $UserDataDst 'Local Storage'),
        (Join-Path $UserDataDst 'Session Storage'),
        (Join-Path $UserDataDst 'Network'),
        (Join-Path $UserDataDst 'Shared Dictionary'),
        (Join-Path $UserDataDst 'blob_storage'),
        (Join-Path $UserDataDst 'WebStorage'),
        (Join-Path $UserDataDst 'Preferences'),
        (Join-Path $UserDataDst 'LOG'),
        (Join-Path $UserDataDst 'LOG.old'),
        (Join-Path $UserDataDst 'lockfile'),
        (Join-Path $UserDataDst 'DIPS'),
        (Join-Path $UserDataDst 'DIPS-wal'),
        (Join-Path $UserDataDst 'DIPS-shm'),
        (Join-Path $UserDataDst 'declarative_performance_observer.db'),
        (Join-Path $UserDataDst 'declarative_performance_observer.db-journal'),
        (Join-Path $UserDataDst 'background-close-confirmed')
    )
}

function Parse-VersionName {
    param([string]$Version)
    if ($Version -match '^v(\d{6})\.(\d+)\.(\d{3,})$') {
        return [pscustomobject]@{
            Raw     = $Version
            Date    = [int]$Matches[1]
            Env     = [int]$Matches[2]
            Minor   = [int]$Matches[3]
            IsDated = $true
        }
    }
    return $null
}

function Get-CurrentVersion {
    param([string]$Repo)
    $path = Join-Path $Repo 'version.txt'
    if (Test-Path -LiteralPath $path) {
        $raw = ([System.IO.File]::ReadAllText($path)).Trim()
        if ($raw) { return $raw }
    }
    $tags = @(& git -C $Repo tag --sort=-creatordate 2>$null)
    if ($tags.Count -gt 0) { return [string]$tags[0] }
    return $null
}

function Get-LatestTag {
    param([string]$Repo)
    return (Get-CurrentVersion -Repo $Repo)
}

function Get-NextVersionName {
    param(
        [string]$Current,
        [bool]$IsMajor,
        [datetime]$Now
    )
    $today = $Now.ToString('yyMMdd')
    $cur = Parse-VersionName $Current

    if ($IsMajor) {
        $envSeq = 1
        if ($cur -and $cur.Date -eq [int]$today) { $envSeq = $cur.Env + 1 }
        return ('v{0}.{1}.001' -f $today, $envSeq)
    }

    if ($cur) {
        return ('v{0}.{1}.{2}' -f $cur.Date.ToString('000000'), $cur.Env, ($cur.Minor + 1).ToString('000'))
    }
    return ('v{0}.1.001' -f $today)
}

function Test-MajorChange {
    param([string[]]$Paths)
    foreach ($p in @($Paths)) {
        if ($p -match '^mirror/metadata/install-identity/') { return $true }
        if ($p -match '^mirror/profile/profiles/(desktop|web)/(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$') { return $true }
        if ($p -match '^mirror/profile/profiles/(desktop|web)/node_modules/') { return $true }
        if ($p -match '^mirror/profile/(dsh-ops|dsh-runtimes)/') { return $true }
    }
    return $false
}

function Get-VersionSortKey {
    param([string]$Version)
    $v = Parse-VersionName $Version
    if ($v) { return ([long]$v.Date * 100000000 + [long]$v.Env * 1000000 + [long]$v.Minor) }
    return 0
}

function Get-DshInstallInfo {
    param([string]$InstallRoot = '')
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Find-DshInstallRoot }
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { return $null }
    $exe = Join-Path $InstallRoot (Get-DshExeName)
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    $item = Get-Item -LiteralPath $exe
    return [pscustomobject]@{
        InstallRoot    = $InstallRoot
        ExePath        = $exe
        ExeName        = $item.Name
        FileVersion    = $item.VersionInfo.FileVersion
        ProductVersion = $item.VersionInfo.ProductVersion
        WriteTime      = $item.LastWriteTime
    }
}

function Get-DshMainProcess {
    $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'DeepSeek%Harness.exe'" -ErrorAction SilentlyContinue
    $procs = @($procs | Where-Object { $_.Name -eq (Get-DshExeName) })
    # The Electron main process is launched with the exe path and no extra
    # arguments. Tool runners and renderers also share the exe name, so they
    # must be filtered out explicitly.
    $candidates = @($procs | Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -notmatch '--type=') -and
            ($_.CommandLine -notmatch 'runner\.js') -and
            ($_.CommandLine -notmatch 'dsh-subprocess-local') -and
            ($_.CommandLine -notmatch '--expose-internals')
        })
    $exact = @($candidates | Where-Object { $_.CommandLine -match ([regex]::Escape((Get-DshExeName)) + '"?\s*$') })
    if ($exact.Count -gt 0) {
        return ($exact | Sort-Object ProcessId | Select-Object -First 1)
    }
    return ($candidates | Sort-Object ProcessId | Select-Object -First 1)
}

function Get-VersionStateEntries {
    param([string]$Repo)
    $dir = Join-Path $Repo 'state\versions'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $items = @(Get-ChildItem -LiteralPath $dir -Filter 'v*.json' -File -ErrorAction SilentlyContinue)
    $out = New-Object System.Collections.ArrayList
    foreach ($f in $items) {
        try {
            $obj = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($obj -and $obj.version) { [void]$out.Add($obj) }
        } catch { }
    }
    return @($out)
}

function Format-VersionIndex {
    param([object[]]$Entries)
    $sorted = @($Entries | Sort-Object @{ Expression = { Get-VersionSortKey $_.version } } -Descending)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# DSH Backup Versions')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Local history of the DSH user environment (profile, plugins, runtimes, credentials).')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Version format: `vYYMMDD.E.SSS`')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- `YYMMDD`: date the current environment baseline was created (Asia/Shanghai)')
    [void]$sb.AppendLine('- `E`: environment change sequence within that date (1, 2, ...; resets to 1 on a new date)')
    [void]$sb.AppendLine('- `SSS`: minor change sequence inside that baseline (001, ...; resets when E changes)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Version | Time | Kind | Trigger | Added | Modified | Deleted | Sessions | Notes |')
    [void]$sb.AppendLine('| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |')
    foreach ($e in $sorted) {
        $notes = @()
        if ($e.dshVersion) { $notes += ('DSH ' + $e.dshVersion) }
        if ($e.plugins -and @($e.plugins).Count -gt 0) { $notes += ('plugin manifests: ' + (@($e.plugins) -join ', ')) }
        if ($e.note) { $notes += [string]$e.note }
        $noteText = ($notes -join '; ')
        if (-not $noteText) { $noteText = '-' }
        $noteText = $noteText.Replace('|', '\|')
        $sessions = 0
        if ($e.sessions) { $sessions = @($e.sessions).Count }
        $time = [string]$e.time
        if ($time -match 'T') { $time = $time -replace 'T', ' ' }
        $kind = 'minor'
        if ($e.kind) { $kind = [string]$e.kind }
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
            $e.version, $time, $kind, $e.trigger, $e.added, $e.modified, $e.deleted, $sessions, $noteText))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Git object integrity is the source of truth; this table is regenerated automatically.')
    return $sb.ToString()
}

function Update-VersionIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][object[]]$Entries
    )
    $path = Join-Path $Repo 'VERSIONS.md'
    $text = Format-VersionIndex -Entries $Entries
    $current = $null
    if (Test-Path -LiteralPath $path) {
        $current = [System.IO.File]::ReadAllText($path)
    }
    if ($current -ne $text) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, $text, $utf8)
    }
}

function Read-TextFileUtf8 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFileUtf8 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [switch]$NoNewline
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    if (-not $NoNewline) { $Text = $Text + "`r`n" }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}
