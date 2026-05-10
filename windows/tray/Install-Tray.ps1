<#
.SYNOPSIS
Installs the DesktopMemoryNode tray app to launch at login.

.DESCRIPTION
Creates a shortcut in the user's Startup folder
(%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\) that runs BackupTray.ps1
in a hidden powershell window when you log in.

Idempotent: replaces any existing shortcut.

.PARAMETER Remove
Delete the startup shortcut.

.PARAMETER LaunchNow
Also start the tray app right now (in addition to installing the shortcut).

.EXAMPLE
.\Install-Tray.ps1
Install the startup shortcut.

.EXAMPLE
.\Install-Tray.ps1 -LaunchNow
Install AND start the tray right now.

.EXAMPLE
.\Install-Tray.ps1 -Remove
Uninstall.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$LaunchNow
)

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$trayScript = Join-Path $here 'BackupTray.ps1'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$shortcut   = Join-Path $startupDir 'DesktopMemoryNode Tray.lnk'

if ($Remove) {
    if (Test-Path $shortcut) {
        Remove-Item $shortcut -Force
        Write-Host "Removed: $shortcut" -ForegroundColor Green
    } else {
        Write-Host "Not installed (nothing to remove)." -ForegroundColor DarkGray
    }
    return
}

if (-not (Test-Path $trayScript)) {
    throw "BackupTray.ps1 not found at $trayScript"
}
if (-not (Test-Path $startupDir)) {
    throw "Startup folder not found at $startupDir"
}

# Build the shortcut: powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <BackupTray.ps1>
$wsh      = New-Object -ComObject WScript.Shell
$lnk      = $wsh.CreateShortcut($shortcut)
$lnk.TargetPath  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`""
$lnk.WorkingDirectory = $here
$lnk.WindowStyle = 7   # Minimized -- we want hidden, but the WindowStyle in the Shortcut object doesn't have a Hidden value; the -WindowStyle Hidden argument handles it
$lnk.Description = 'DesktopMemoryNode tray app -- backup status and on-demand actions'
$lnk.IconLocation = "$env:WINDIR\System32\imageres.dll,77"  # shield icon
$lnk.Save()

Write-Host "Installed: $shortcut" -ForegroundColor Green
Write-Host "Will launch at next login." -ForegroundColor Cyan

if ($LaunchNow) {
    Write-Host "Launching tray now..." -ForegroundColor Cyan
    Start-Process -FilePath $lnk.TargetPath -ArgumentList $lnk.Arguments -WorkingDirectory $here -WindowStyle Hidden
}
