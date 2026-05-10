<#
.SYNOPSIS
Runs restic's integrity check against the encrypted repo on the memorybox.

.DESCRIPTION
Catches repo corruption (bit-rot on the NAS, interrupted writes, etc.) before it
matters. The default check verifies the repository structure (indexes, packs,
tree references) but does NOT re-read the entire data payload. Pass -ReadData for
the full read, which downloads everything and is bandwidth-heavy.

Scheduled weekly by Install-Schedule.ps1 (Sun 04:00).

.PARAMETER ReadData
Pass --read-data to also verify the actual data blobs match their hashes.
Slow and bandwidth-heavy; run periodically (e.g. quarterly), not weekly.

.PARAMETER ReadDataSubset
Pass --read-data-subset=<value> to verify a fraction. e.g. '5%' or '10%'.
Cheaper than full --read-data while still catching some bit-rot.

.EXAMPLE
.\Invoke-Verify.ps1
Standard structural check.

.EXAMPLE
.\Invoke-Verify.ps1 -ReadData
Full data verification (slow).

.EXAMPLE
.\Invoke-Verify.ps1 -ReadDataSubset '5%'
Sample-based data verification.
#>
[CmdletBinding()]
param(
    [switch]$ReadData,
    [string]$ReadDataSubset
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path $here '..\lib\Memorybox.psm1'
Import-Module $libPath -Force

$lock = $null

try {
    Assert-MemoryboxReady
    Connect-MemoryboxSmb

    $lock = Lock-NodeOperation -Name 'verify'
    try { Invoke-Restic unlock --remove-all 2>$null | Out-Null } catch {}

    Write-DmnLog "Verify starting (ReadData=$ReadData ReadDataSubset='$ReadDataSubset')" -Kind 'verify'

    $resticArgs = @('check')
    if ($ReadData)        { $resticArgs += '--read-data' }
    if ($ReadDataSubset)  { $resticArgs += "--read-data-subset=$ReadDataSubset" }

    Write-DmnLog "restic $($resticArgs -join ' ')" -Kind 'verify'
    Invoke-Restic @resticArgs 2>&1 | Tee-Object -FilePath (Get-DmnLogPath -Kind 'verify') -Append
    if ($LASTEXITCODE -ne 0) {
        throw "restic check failed (exit $LASTEXITCODE)."
    }

    Write-DmnLog "Verify OK" -Kind 'verify'
    Set-NodeState -Updates @{
        LastVerifyAt = (Get-Date).ToString('o')
        LastVerifyOk = $true
    }
} catch {
    $err = $_.Exception.Message
    Write-DmnLog "Verify FAILED: $err" -Kind 'verify' -Level ERROR
    Set-NodeState -Updates @{
        LastVerifyAt = (Get-Date).ToString('o')
        LastVerifyOk = $false
    }
    Send-MemoryboxToast -Title "Repo verify FAILED" -Body "Restic integrity check failed: $err  $(Get-DmnSupportLine)" -Level Error
    exit 1
} finally {
    if ($lock) { Unlock-NodeOperation -Handle $lock -Name 'verify' }
}
