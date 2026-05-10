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
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$trayScript  = Join-Path $here 'BackupTray.ps1'
$startupDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startMenu   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$desktopDir  = [Environment]::GetFolderPath('Desktop')

$shortcut    = Join-Path $startupDir 'Memory Box (auto-start).lnk'
$startMenuLnk = Join-Path $startMenu 'Memory Box.lnk'
$desktopLnk  = Join-Path $desktopDir 'Memory Box.lnk'

function New-TrayShortcut {
    param(
        [string]$Path,
        [string]$Description,
        [string[]]$ExtraArgs = @()
    )
    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`""
    if ($ExtraArgs.Count -gt 0) { $argString += ' ' + ($ExtraArgs -join ' ') }

    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($Path)
    $lnk.TargetPath       = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments        = $argString
    $lnk.WorkingDirectory = $here
    $lnk.WindowStyle      = 1   # 1 = Normal. Powershell console hidden via the -WindowStyle Hidden arg above.
    $lnk.Description      = $Description
    $lnk.IconLocation     = "$env:WINDIR\System32\imageres.dll,77"
    $lnk.Save()
}

if ($Remove) {
    foreach ($p in @($shortcut, $startMenuLnk, $desktopLnk)) {
        if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Removed: $p" -ForegroundColor Green }
    }
    return
}

if (-not (Test-Path $trayScript)) { throw "BackupTray.ps1 not found at $trayScript" }
if (-not (Test-Path $startupDir)) { throw "Startup folder not found at $startupDir" }

# Startup shortcut: launches the tray (background)
New-TrayShortcut -Path $shortcut     -Description 'Memory Box -- launches the tray at login'

# Desktop + Start Menu shortcuts: open the Status dashboard directly (no extra tray instance)
New-TrayShortcut -Path $startMenuLnk -Description 'Open Memory Box dashboard' -ExtraArgs @('-ShowStatus')
New-TrayShortcut -Path $desktopLnk   -Description 'Open Memory Box dashboard' -ExtraArgs @('-ShowStatus')

Write-Host "Installed:" -ForegroundColor Green
Write-Host "  $shortcut" -ForegroundColor DarkGray
Write-Host "  $startMenuLnk" -ForegroundColor DarkGray
Write-Host "  $desktopLnk" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Tip: right-click the desktop shortcut -> Pin to taskbar." -ForegroundColor Cyan

if ($LaunchNow) {
    Write-Host "Launching tray now..." -ForegroundColor Cyan
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`"" `
        -WorkingDirectory $here -WindowStyle Hidden
}
