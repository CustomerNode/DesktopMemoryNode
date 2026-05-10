<#
.SYNOPSIS
Installs the BurntToast PowerShell module so DesktopMemoryNode can show sticky toasts.

.DESCRIPTION
BurntToast provides programmatic access to Windows toast notifications. Without it,
Send-MemoryboxToast falls back to NotifyIcon balloons (which auto-dismiss after 15s);
with it, toasts use the "Reminder" scenario and stay on screen until you click Dismiss.

Installed for the CURRENT USER only (no admin required).

Idempotent: no-op if BurntToast is already installed and importable.

.PARAMETER Force
Reinstall even if BurntToast is already present.

.EXAMPLE
.\Install-Notifications.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $Force) {
    $existing = Get-Module -ListAvailable -Name BurntToast
    if ($existing) {
        Write-Host "BurntToast already installed: $($existing[0].Version) at $($existing[0].ModuleBase)" -ForegroundColor Green
        return
    }
}

# Ensure PSGallery is trusted (one-time, current user only)
try {
    $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
    if ($repo.InstallationPolicy -ne 'Trusted') {
        Write-Host "Trusting PSGallery (current user)..." -ForegroundColor DarkGray
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
    }
} catch {
    Write-Warning "Could not query/update PSGallery trust: $($_.Exception.Message). Install will probably still work but may prompt."
}

Write-Host "Installing BurntToast (CurrentUser scope)..." -ForegroundColor Cyan
Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber

$installed = Get-Module -ListAvailable -Name BurntToast
if (-not $installed) { throw "BurntToast install reported success but module is not discoverable." }
Write-Host "Installed BurntToast $($installed[0].Version)." -ForegroundColor Green

# Quick smoke test (won't actually pop a toast — just imports)
try {
    Import-Module BurntToast -ErrorAction Stop
    Write-Host "BurntToast imports cleanly." -ForegroundColor Green
} catch {
    Write-Warning "BurntToast installed but failed to import: $($_.Exception.Message)"
}
