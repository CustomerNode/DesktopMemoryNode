<#
.SYNOPSIS
End-to-end setup for a new Windows node. Idempotent — safe to re-run.

.DESCRIPTION
Runs, in order:
  1. Set-MemoryboxVars.ps1   (prompts only for missing values)
  2. Install-Restic.ps1      (no-op if already installed)
  3. Test-Setup.ps1          (preflight diagnostic)

After this completes successfully, the node is ready for restic repo init and
the first backup (covered separately).

.EXAMPLE
.\Setup-Node.ps1
#>
[CmdletBinding()]
param()

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=== Step 1/3: Memorybox env vars ===" -ForegroundColor Cyan
& (Join-Path $here 'Set-MemoryboxVars.ps1')

Write-Host ""
Write-Host "=== Step 2/3: restic ===" -ForegroundColor Cyan
& (Join-Path $here 'Install-Restic.ps1')

Write-Host ""
Write-Host "=== Step 3/3: Preflight checks ===" -ForegroundColor Cyan
& (Join-Path $here 'Test-Setup.ps1')

Write-Host ""
Write-Host "Setup complete. Next: initialize the restic repo and configure the backup schedule." -ForegroundColor Cyan
