<#
.SYNOPSIS
File-level restore CLI. Pulls one or more paths from a snapshot back to a destination.

.DESCRIPTION
SAFETY: Destination is REQUIRED. The script never restores in-place over your real
filesystem unless you explicitly point it there. The default suggestion is a fresh
folder under your home directory.

Three lookup modes:
  - -Latest                   : pick the most recent snapshot
  - -SnapshotId <id>          : pick a specific snapshot by short or full ID
  - (default, no flag)        : list snapshots and prompt you to pick

Pass -Path one or more times to restrict what gets restored. Without -Path, the
ENTIRE snapshot is restored under -Destination (could be large -- be intentional).

.PARAMETER Destination
Where to restore TO. Required. Will be created if missing.

.PARAMETER SnapshotId
Restore from this specific snapshot ID (short or full).

.PARAMETER Latest
Restore from the most recent snapshot.

.PARAMETER Path
One or more paths inside the snapshot to restore (--include patterns).
Without -Path, the entire snapshot is restored.

.PARAMETER PromptPassword
Read the encryption password interactively instead of using $env:enc_pswd. Useful when
you're recovering on a fresh machine that doesn't have the env var set yet.

.PARAMETER List
List all snapshots and exit (no restore).

.EXAMPLE
.\Restore-File.ps1 -List
List available snapshots.

.EXAMPLE
.\Restore-File.ps1 -Latest -Path 'C:\Users\donca\Documents\report.docx' -Destination 'C:\Users\donca\restored'
Restore one file from the latest snapshot.

.EXAMPLE
.\Restore-File.ps1 -SnapshotId 61df23cb -Destination 'C:\restore-staging' -PromptPassword
Pick a specific snapshot, type the password fresh.
#>
[CmdletBinding(DefaultParameterSetName='Pick')]
param(
    [Parameter(Mandatory)] [string]$Destination,
    [Parameter(ParameterSetName='Specific', Mandatory)] [string]$SnapshotId,
    [Parameter(ParameterSetName='Latest',   Mandatory)] [switch]$Latest,
    [string[]]$Path,
    [switch]$PromptPassword,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path $here '..\lib\Memorybox.psm1'
Import-Module $libPath -Force

Assert-MemoryboxReady
Connect-MemoryboxSmb

if ($PromptPassword) {
    $typed = Get-EncryptionPassword -Prompt
    Set-ResticPasswordOverride -Password $typed
}

try {
    # Always show the snapshot list (also satisfies -List)
    Write-Host ""
    Write-Host "Available snapshots:" -ForegroundColor Cyan
    Invoke-Restic snapshots
    if ($List) { return }

    $rawSnaps = Invoke-Restic snapshots --json 2>$null
    if (-not $rawSnaps) { throw "No snapshots in repo." }
    $snapshots = @(($rawSnaps | Out-String).Trim() | ConvertFrom-Json)

    $picked = $null
    if ($Latest) {
        $picked = $snapshots | Sort-Object @{Expression={[datetime]$_.time}} -Descending | Select-Object -First 1
    } elseif ($SnapshotId) {
        $picked = $snapshots | Where-Object { $_.id -like "$SnapshotId*" -or $_.short_id -eq $SnapshotId } | Select-Object -First 1
        if (-not $picked) { throw "No snapshot matches id '$SnapshotId'." }
    } else {
        Write-Host ""
        $sid = Read-Host "Snapshot ID to restore from (short id from the list above)"
        $picked = $snapshots | Where-Object { $_.short_id -eq $sid -or $_.id -like "$sid*" } | Select-Object -First 1
        if (-not $picked) { throw "No snapshot matches '$sid'." }
    }

    Write-Host ""
    Write-Host "Restoring snapshot $($picked.short_id) ($($picked.time))" -ForegroundColor Cyan
    Write-Host "Destination     : $Destination" -ForegroundColor Cyan
    if ($Path) { Write-Host "Include paths   : $($Path -join ', ')" -ForegroundColor Cyan }
    else       { Write-Host "Include paths   : (entire snapshot)" -ForegroundColor Yellow }
    Write-Host ""

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-Host "Created destination $Destination" -ForegroundColor DarkGray
    }

    $resticArgs = @('restore', $picked.id, '--target', $Destination)
    foreach ($p in $Path) { $resticArgs += @('--include', $p) }

    Invoke-Restic @resticArgs
    if ($LASTEXITCODE -ne 0) { throw "restic restore failed (exit $LASTEXITCODE)." }

    Write-Host ""
    Write-Host "Restored to $Destination" -ForegroundColor Green
    Write-Host "Top-level contents:" -ForegroundColor DarkGray
    Get-ChildItem -Path $Destination | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
} finally {
    if ($PromptPassword) { Clear-ResticPasswordOverride }
}
