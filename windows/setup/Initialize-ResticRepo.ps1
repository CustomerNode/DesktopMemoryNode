<#
.SYNOPSIS
Initializes (or verifies) this node's encrypted restic repository on the memorybox.

.DESCRIPTION
Idempotent. If the repo already exists at \\<host>\home\dmn-<nodename>\restic-repo\
and the configured encryption password unlocks it, this is a no-op.

If the repo does not exist, it's created using the password from $env:enc_pswd.
The user-scoped env var is the source of truth for the encryption key -- set it
once with `[Environment]::SetEnvironmentVariable('enc_pswd', '<your password>', 'User')`
and DesktopMemoryNode will use it for all automated operations.

.PARAMETER Reuse
Allow operating against an existing repo even if -Force is not passed.
(Default: existing repos are reused silently -- this switch is for symmetry.)

.PARAMETER WhatIf
Preview without making changes.

.EXAMPLE
.\Initialize-ResticRepo.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Reuse
)

$ErrorActionPreference = 'Stop'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) 'lib\Memorybox.psm1'
Import-Module $libPath -Force

# --- Preflight: env vars present, NAS reachable ---
$missing = Get-MissingMemoryboxVars
if ($missing.Count -gt 0) {
    throw "Missing required env vars: $($missing -join ', '). Run setup\Set-MemoryboxVars.ps1 (and set `$env:enc_pswd at User scope)."
}

$cfg = Get-MemoryboxConfig
Write-Host "Node    : $($cfg.NodeName)" -ForegroundColor Cyan
Write-Host "Repo    : $($cfg.ResticRepoPath)" -ForegroundColor Cyan
Write-Host ""

# --- Ensure SMB session ---
Connect-MemoryboxSmb

# --- Ensure node directory exists on NAS ---
if (-not (Test-Path $cfg.NodePath)) {
    if ($PSCmdlet.ShouldProcess($cfg.NodePath, "Create node directory")) {
        New-Item -ItemType Directory -Path $cfg.NodePath -Force | Out-Null
        Write-Host "Created node directory: $($cfg.NodePath)" -ForegroundColor Green
    }
}

# --- Check if restic repo already initialized ---
$repoConfigFile = Join-Path $cfg.ResticRepoPath 'config'
$alreadyInit    = Test-Path $repoConfigFile

if ($alreadyInit) {
    Write-Host "Repo already exists at $($cfg.ResticRepoPath). Verifying password unlocks it..." -ForegroundColor Yellow
    Invoke-Restic snapshots --no-lock --quiet --json *> $null
    if ($LASTEXITCODE -ne 0) {
        $msg = "Repo exists but the configured enc_pswd does NOT unlock it. " +
               "Either the password env var is wrong, or this node directory belongs to a previous install. " +
               "Aborting to avoid data loss. Inspect: $($cfg.ResticRepoPath)"
        throw $msg
    }
    Write-Host "OK -- existing repo unlocks with the configured password." -ForegroundColor Green
    return
}

# --- Initialize a new repo ---
Write-Host "Repo does not exist. Initializing new encrypted repo..." -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess($cfg.ResticRepoPath, "Initialize new restic repo")) {
    if (-not (Test-Path $cfg.ResticRepoPath)) {
        New-Item -ItemType Directory -Path $cfg.ResticRepoPath -Force | Out-Null
    }
    Invoke-Restic init
    if ($LASTEXITCODE -ne 0) {
        throw "restic init failed (exit $LASTEXITCODE). Check the output above."
    }
    Write-Host ""
    Write-Host "Repo initialized successfully." -ForegroundColor Green
    $reminderLine1 = "REMINDER: the encryption key is the value of the enc_pswd env var."
    $reminderLine2 = "If you lose it, your backups are unrecoverable. Save a copy somewhere safe (password manager, paper in a safe)."
    Write-Host $reminderLine1 -ForegroundColor Yellow
    Write-Host $reminderLine2 -ForegroundColor Yellow
}
