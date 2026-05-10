<#
.SYNOPSIS
Runs a backup of the configured targets to the memorybox.

.DESCRIPTION
This is the main backup runner. Called by the Windows Task Scheduler daily, and by the
tray widget's "Snapshot now" action.

Behavior:
  1. Asserts all required env vars are present (toasts on failure).
  2. Acquires an exclusive lock so concurrent runs can't collide.
  3. Reads include/exclude paths from targets.json (or defaults).
  4. Runs `restic backup` against \\<host>\home\dmn-<nodename>\restic-repo\.
  5. Logs every line to logs\backup-YYYY-MM-DD.log under %LOCALAPPDATA%\DesktopMemoryNode\.
  6. Updates state.json with the result.
  7. Sends a toast on success (optional) and on failure (always).

.PARAMETER Tag
Snapshot tag. Default 'scheduled'. The tray widget passes 'manual' for on-demand snapshots.

.PARAMETER QuietOnSuccess
Suppress the success toast. Useful for the daily scheduled run if you don't want a daily toast.

.PARAMETER DryRun
Pass --dry-run to restic -- show what would be backed up without writing data.

.EXAMPLE
.\Invoke-Backup.ps1
Run a normal scheduled backup.

.EXAMPLE
.\Invoke-Backup.ps1 -Tag manual
Run a manual snapshot from the tray widget.

.EXAMPLE
.\Invoke-Backup.ps1 -DryRun
Preview without writing.
#>
[CmdletBinding()]
param(
    [string]$Tag = 'scheduled',
    [switch]$QuietOnSuccess,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path $here '..\lib\Memorybox.psm1'
Import-Module $libPath -Force

$started = Get-Date
$lock    = $null

try {
    Assert-MemoryboxReady

    $cfg     = Get-MemoryboxConfig
    $targets = Get-BackupTargets
    if ($targets.include.Count -eq 0) {
        throw "No backup targets configured. Run setup\Set-BackupTargets.ps1."
    }

    Write-DmnLog "Backup starting (tag=$Tag, node=$($cfg.NodeName))"
    Write-DmnLog ("Include: " + (($targets.include) -join '; '))
    if ($targets.exclude) { Write-DmnLog ("Exclude: " + (($targets.exclude) -join '; ')) }

    Connect-MemoryboxSmb

    $lock = Lock-NodeOperation -Name 'backup'

    # Clear any stale restic locks left behind by a previous crashed run.
    # Safe because our own file lock above already ensured exclusive access.
    try { Invoke-Restic unlock --remove-all 2>$null | Out-Null } catch {}

    # Performance tuning:
    #   --pack-size 64     : bigger packs = fewer SMB roundtrips (default 16 MB)
    #   --read-concurrency 4 : parallel source reads (default 2)
    # The FIRST backup is unavoidably slow because every byte must be uploaded.
    # Subsequent backups are incremental (only changed files) and finish in minutes.
    $resticArgs = @(
        'backup',
        '--tag', $Tag,
        '--pack-size', '64',
        '--read-concurrency', '4'
    )
    if ($DryRun) { $resticArgs += '--dry-run' }
    foreach ($e in $targets.exclude) { $resticArgs += @('--exclude', $e) }
    $resticArgs += $targets.include

    Write-DmnLog "restic $($resticArgs -join ' ')"

    $logPath = Get-DmnLogPath -Kind 'backup'
    Invoke-Restic @resticArgs 2>&1 | Tee-Object -FilePath $logPath -Append
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-DmnLog "Backup OK (exit 0)"
        Set-NodeState -Updates @{
            LastBackupAt    = (Get-Date).ToString('o')
            LastBackupOk    = $true
            LastBackupError = $null
        }
        if (-not $QuietOnSuccess) {
            $duration = [int]((Get-Date) - $started).TotalSeconds
            Send-MemoryboxToast -Title "Backup complete" -Body "Snapshot saved to memorybox in ${duration}s." -Level Success
        }
    } elseif ($exitCode -eq 3) {
        # restic exit 3 = some files were skipped (unreadable / disappeared during run) but the snapshot succeeded
        Write-DmnLog "Backup completed with warnings (exit 3 -- some files skipped)" -Level WARN
        Set-NodeState -Updates @{
            LastBackupAt    = (Get-Date).ToString('o')
            LastBackupOk    = $true
            LastBackupError = "exit 3 -- some files skipped"
        }
        if (-not $QuietOnSuccess) {
            Send-MemoryboxToast -Title "Backup complete (warnings)" -Body "Snapshot saved but some files were skipped. Check the log." -Level Warning
        }
    } else {
        throw "restic backup failed (exit $exitCode). See $logPath."
    }
} catch {
    $err = $_.Exception.Message
    Write-DmnLog "Backup FAILED: $err" -Level ERROR
    Set-NodeState -Updates @{
        LastBackupAt    = (Get-Date).ToString('o')
        LastBackupOk    = $false
        LastBackupError = $err
    }
    Send-MemoryboxToast -Title "Backup FAILED" -Body "Backup did not complete: $err  $(Get-DmnSupportLine)" -Level Error
    exit 1
} finally {
    if ($lock) { Unlock-NodeOperation -Handle $lock -Name 'backup' }
}
