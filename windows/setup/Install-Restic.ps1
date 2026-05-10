<#
.SYNOPSIS
Installs restic on Windows via winget. Idempotent — no-op if already installed.

.DESCRIPTION
Restic is the encrypted, deduplicating backup engine used by DesktopMemoryNode.
Install adds it to user PATH; existing shells will need to restart to see the
`restic` command.

Workaround for a known winget bug: the portable install of restic.restic
sometimes drops the binary as `restic_<version>_windows_amd64.exe` without
creating a `restic.exe` alias on PATH. This script detects that and creates
the alias if missing.

.EXAMPLE
.\Install-Restic.ps1
#>
[CmdletBinding()]
param()

function Find-ResticExe {
    $cmd = Get-Command restic -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $pkgRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    $shim = Get-ChildItem $pkgRoot -Filter "restic.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shim) { return $shim.FullName }

    $versioned = Get-ChildItem $pkgRoot -Filter "restic_*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($versioned) { return $versioned.FullName }

    return $null
}

function Ensure-ResticAlias {
    $existing = Find-ResticExe
    if (-not $existing -or (Split-Path -Leaf $existing) -eq 'restic.exe') { return $existing }

    $shimPath = Join-Path (Split-Path -Parent $existing) 'restic.exe'
    if (-not (Test-Path $shimPath)) {
        Copy-Item $existing $shimPath -Force
        Write-Host "  Created restic.exe alias at $shimPath" -ForegroundColor DarkGray
    }
    return $shimPath
}

$existing = Get-Command restic -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "restic already installed: $($existing.Source)" -ForegroundColor Green
    & restic version
    return
}

# Maybe it's installed but missing the alias
$found = Find-ResticExe
if ($found) {
    Write-Host "restic binary found at: $found" -ForegroundColor Green
    $shim = Ensure-ResticAlias
    & $shim version
    Write-Host ""
    Write-Host "Note: restic is on PATH but won't appear in this shell until you start a new one." -ForegroundColor DarkGray
    return
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install App Installer from the Microsoft Store, then re-run."
}

Write-Host "Installing restic via winget..." -ForegroundColor Cyan
winget install --id restic.restic -e --source winget `
    --accept-package-agreements --accept-source-agreements

if ($LASTEXITCODE -ne 0) {
    throw "winget install failed with exit code $LASTEXITCODE."
}

# winget portable-install bug workaround: ensure restic.exe alias exists
$shim = Ensure-ResticAlias
if (-not $shim) {
    throw "restic install reported success but binary not found under WinGet packages dir."
}

Write-Host ""
Write-Host "restic installed. Open a new terminal to pick it up on PATH." -ForegroundColor Green
& $shim version
