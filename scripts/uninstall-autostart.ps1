# Remove the DSH startup watcher (scheduled task or Startup shortcut).
# ASCII only: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')

$taskName = 'DSH-AutoBackup-Watch'
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'DSH Auto Backup.lnk'
$vbsPath = Join-Path $repo 'state\start-watcher.vbs'

Write-Host 'Removing DSH incremental backup autostart...' -ForegroundColor Cyan

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Scheduled task removed (if it existed): $taskName"
} catch {
    Write-Host ("Could not remove scheduled task: " + $_.Exception.Message) -ForegroundColor Yellow
}

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host "Removed startup shortcut: $shortcutPath"
}
if (Test-Path -LiteralPath $vbsPath) {
    Remove-Item -LiteralPath $vbsPath -Force
    Write-Host "Removed launcher: $vbsPath"
}

$watchers = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*watch-dsh.ps1*' })
foreach ($w in $watchers) {
    try {
        Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop
        Write-Host "Stopped watcher process: $($w.ProcessId)"
    } catch {
        Write-Host ("Could not stop watcher $($w.ProcessId): " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Done. Existing backup versions are untouched.'
exit 0
