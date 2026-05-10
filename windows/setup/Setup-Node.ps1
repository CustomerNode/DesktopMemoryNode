<#
.SYNOPSIS
End-to-end setup for a new Windows node. Idempotent -- safe to re-run.

.DESCRIPTION
Runs, in order:
  1. Set-MemoryboxVars.ps1    -- prompts for any missing connection vars + node name
  2. Install-Restic.ps1       -- installs restic via winget if not present
  3. Initialize-ResticRepo.ps1 -- creates the encrypted repo on the NAS (uses $env:enc_pswd)
  4. Set-BackupTargets.ps1    -- interactive editor for include/exclude paths (skipped if already configured)
  5. Install-Schedule.ps1     -- registers the scheduled tasks (daily/weekly/monthly)
  6. Test-Setup.ps1           -- preflight checklist

After this completes, the node will run automatic backups daily at 02:00.

The encryption password env var ($env:enc_pswd, User scope) must be set BEFORE running
this script. If it's missing, step 3 will fail with a clear error.

.PARAMETER SkipSchedule
Skip the scheduled-task registration step (useful when developing).

.EXAMPLE
.\Setup-Node.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipSchedule
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Step($n, $total, $title) {
    Write-Host ""
    Write-Host "=== Step $n/$total : $title ===" -ForegroundColor Cyan
}

$total = if ($SkipSchedule) { 5 } else { 6 }
$n = 0

$n++; Step $n $total "Memorybox env vars (connection + node name)"
& (Join-Path $here 'Set-MemoryboxVars.ps1')

$n++; Step $n $total "Restic install"
& (Join-Path $here 'Install-Restic.ps1')

$n++; Step $n $total "Encrypted restic repo on the NAS"
$encSet = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('enc_pswd', 'User'))
if (-not $encSet) {
    Write-Host "FATAL: `$env:enc_pswd is not set (User scope)." -ForegroundColor Red
    Write-Host "Set it once with: [Environment]::SetEnvironmentVariable('enc_pswd', '<your password>', 'User')" -ForegroundColor Yellow
    Write-Host "Then re-run this script." -ForegroundColor Yellow
    exit 1
}
& (Join-Path $here 'Initialize-ResticRepo.ps1')

$n++; Step $n $total "Backup targets (paths to include/exclude)"
Import-Module (Join-Path (Split-Path -Parent $here) 'lib\Memorybox.psm1') -Force
if (Test-Path (Get-DmnTargetsPath)) {
    Write-Host "targets.json already exists. Skipping (run setup\Set-BackupTargets.ps1 to edit later)." -ForegroundColor DarkGray
} else {
    Write-Host "No targets.json yet -- saving defaults (user folders)." -ForegroundColor DarkGray
    $defaults = Get-DefaultBackupTargets
    Set-BackupTargets -Include $defaults.include -Exclude $defaults.exclude
    Write-Host "Saved defaults. Edit later with setup\Set-BackupTargets.ps1." -ForegroundColor Green
}

if (-not $SkipSchedule) {
    $n++; Step $n $total "Scheduled tasks"
    & (Join-Path $here 'Install-Schedule.ps1')
}

$n++; Step $n $total "Preflight checks"
& (Join-Path $here 'Test-Setup.ps1')

Write-Host ""
Write-Host "Setup complete. The node will run its first scheduled backup at 02:00." -ForegroundColor Cyan
Write-Host "To run a backup right now: windows\agent\Invoke-Backup.ps1 -Tag manual" -ForegroundColor Cyan
