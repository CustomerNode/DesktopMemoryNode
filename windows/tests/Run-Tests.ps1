<#
.SYNOPSIS
Runs the Pester test suite for windows/lib/Memorybox.psm1.

.DESCRIPTION
Installs Pester (CurrentUser scope) if missing, then invokes Pester against
windows/tests. Exits non-zero if any test fails so this can be used in CI.

.EXAMPLE
.\Run-Tests.ps1
.EXAMPLE
.\Run-Tests.ps1 -Detailed
#>
[CmdletBinding()]
param(
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Select-Object -First 1
if (-not $pester) {
    Write-Host "Installing Pester (CurrentUser)..." -ForegroundColor Cyan
    try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch {}
    Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
}
Import-Module Pester -MinimumVersion 5.0.0 -Force

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$config = New-PesterConfiguration
$config.Run.Path           = $here
$config.Run.PassThru       = $true
$config.Output.Verbosity   = if ($Detailed) { 'Detailed' } else { 'Normal' }
$config.TestResult.Enabled = $false

$result = Invoke-Pester -Configuration $config

if ($result.FailedCount -gt 0) {
    Write-Host ""
    Write-Host "$($result.FailedCount) test(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "$($result.PassedCount) test(s) passed." -ForegroundColor Green
exit 0
