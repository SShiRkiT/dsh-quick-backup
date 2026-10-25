# Watches for DeepSeek Harness starts and triggers an incremental backup.
# Started hidden at logon by the scheduled task "DSH-AutoBackup-Watch".
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param(
    [int]$PollSeconds = 8,
    [switch]$Once,
    [switch]$SkipInitial,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

$logDir = Join-Path $repo 'state\logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logPath = Join-Path $logDir 'watcher.log'

function Write-WatcherLog {
    param([string]$Message, [string]$Level = 'INFO')
    if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 4MB)) {
        Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force
    }
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Start-Backup {
    $backup = Join-Path $repo 'scripts\backup.ps1'
    if (-not (Test-Path -LiteralPath $backup)) {
        Write-WatcherLog -Message "backup.ps1 not found: $backup" -Level ERROR
        return
    }
    if ($NoBackup) {
        Write-WatcherLog -Message 'NoBackup mode: would have launched the backup now.'
        return
    }
    $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Trigger startup' -f $backup
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Write-WatcherLog -Message 'Launched incremental backup (hidden).'
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\DSH-AutoBackup-Watcher')
$locked = $false
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) {
        Write-WatcherLog -Message 'Another watcher instance is already running; exiting.'
        exit 0
    }

    Write-WatcherLog -Message ("Watcher started (pid=$PID, poll=${PollSeconds}s, once=$Once, skipInitial=$SkipInitial)")

    $lastMainPid = $null
    $lastLaunch = [datetime]::MinValue
    $firstPoll = $true
    $missingPolls = 0

    while ($true) {
        try {
            $main = Get-DshMainProcess
            $mainPid = $null
            if ($main) { $mainPid = [int]$main.ProcessId }

            if ($mainPid) {
                $missingPolls = 0
                if ($mainPid -ne $lastMainPid) {
                    $isInitial = ($firstPoll -and ($lastMainPid -eq $null))
                    $lastMainPid = $mainPid
                    Write-WatcherLog -Message ("Detected DeepSeek Harness main process (pid=$mainPid).")

                    $shouldTrigger = $true
                    if ($isInitial -and $SkipInitial) {
                        $shouldTrigger = $false
                        Write-WatcherLog -Message 'SkipInitial: existing instance recorded, not backing up.'
                    }
                    if ($shouldTrigger) {
                        $since = ((Get-Date) - $lastLaunch).TotalSeconds
                        if ($since -lt 90) {
                            Write-WatcherLog -Message ("Skipping trigger: last backup launch was {0:N0}s ago." -f $since)
                        } else {
                            $lastLaunch = Get-Date
                            Start-Sleep -Seconds 6
                            Start-Backup
                        }
                    }
                }
            } else {
                # Do not treat one failed WMI poll as an app exit.
                $missingPolls++
                if ($missingPolls -ge 3 -and $lastMainPid) {
                    $lastMainPid = $null
                    Write-WatcherLog -Message 'DeepSeek Harness main process exited (3 consecutive polls without it).'
                }
            }
            $firstPoll = $false
        } catch {
            Write-WatcherLog -Message ("Watcher loop error: " + $_.Exception.Message) -Level ERROR
        }

        if ($Once) { break }
        Start-Sleep -Seconds $PollSeconds
    }
} catch {
    Write-WatcherLog -Message ("Watcher fatal error: " + $_.Exception.Message) -Level ERROR
    exit 1
} finally {
    if ($locked) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
}
