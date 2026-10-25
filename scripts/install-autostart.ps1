# Register the DSH startup watcher so it runs automatically at every logon.
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param(
    [switch]$StartNow,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

$taskName = 'DSH-AutoBackup-Watch'
$watchScript = Join-Path $PSScriptRoot 'watch-dsh.ps1'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'DSH Auto Backup.lnk'
$vbsPath = Join-Path $repo 'state\start-watcher.vbs'
$logDir = Join-Path $repo 'state\logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

Write-Host 'Installing DSH incremental backup autostart...' -ForegroundColor Cyan

function Install-StartupFolderFallback {
    Write-Host 'Falling back to the Startup folder method...' -ForegroundColor Yellow
    $vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$watchScript""", 0, False
"@
    Write-TextFileUtf8 -Path $vbsPath -Text $vbs

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = 'wscript.exe'
    $sc.Arguments = '"' + $vbsPath + '"'
    $sc.WorkingDirectory = $repo
    $sc.WindowStyle = 7
    $sc.Description = 'Start the DeepSeek Harness incremental backup watcher'
    $sc.Save()
    Write-Host "Created startup shortcut: $shortcutPath" -ForegroundColor Green
}

try {
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watchScript)
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    try { $trigger.Delay = 'PT20S' } catch { }
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited

    if ($Force) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Starts the DSH incremental backup watcher at logon (local only).' -Force | Out-Null

    Write-Host "Scheduled task registered: $taskName" -ForegroundColor Green
    Write-Host 'Trigger: at logon of the current user (20 s delay).'
} catch {
    Write-Host ("Scheduled task registration failed: " + $_.Exception.Message) -ForegroundColor Yellow
    Install-StartupFolderFallback
}

if ($StartNow) {
    Write-Host 'Starting the watcher now (existing DSH instance will not trigger a backup)...' -ForegroundColor Cyan
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*watch-dsh.ps1*' })
    if ($running.Count -eq 0) {
        $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -SkipInitial' -f $watchScript
        Start-Process -FilePath $powerShell -ArgumentList $argLine -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 2
    } else {
        Write-Host ('Watcher already running (PID: ' + (($running | ForEach-Object { $_.ProcessId }) -join ', ') + ').')
    }
}

$watcherLog = Join-Path $logDir 'watcher.log'
if (Test-Path -LiteralPath $watcherLog) {
    Write-Host ''
    Write-Host 'Last watcher log lines:'
    Get-Content -LiteralPath $watcherLog -Tail 5 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-Host 'Autostart installation finished. The watcher checks for DeepSeek Harness every 8 seconds.'
Write-Host 'To remove it later: powershell -ExecutionPolicy Bypass -File scripts\uninstall-autostart.ps1'
exit 0
