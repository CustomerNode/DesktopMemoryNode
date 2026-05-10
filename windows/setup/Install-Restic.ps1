<#
.SYNOPSIS
Installs restic on Windows via winget. Idempotent — no-op if already installed.

.DESCRIPTION
Restic is the encrypted, deduplicating backup engine used by DesktopMemoryNode.
Install adds it to user PATH; existing shells will need to restart to see the
`restic` command.

.EXAMPLE
.\Install-Restic.ps1
#>
[CmdletBinding()]
param()

$existing = Get-Command restic -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "restic already installed: $($existing.Source)" -ForegroundColor Green
    & restic version
    return
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install App Installer from the Microsoft Store, then re-run."
}

Write-Host "Installing restic via winget..." -ForegroundColor Cyan
winget install --id restic.restic -e --source winget `
    --accept-package-agreements --accept-source-agreements --silent

if ($LASTEXITCODE -ne 0) {
    throw "winget install failed with exit code $LASTEXITCODE."
}

Write-Host ""
Write-Host "restic installed. Open a new terminal to pick it up on PATH." -ForegroundColor Green
Write-Host "(In this shell you can use the full path under %LOCALAPPDATA%\Microsoft\WinGet\Packages\restic.restic_*\.)" -ForegroundColor DarkGray
