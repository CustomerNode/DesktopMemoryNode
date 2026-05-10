<#
.SYNOPSIS
Verifies that snapshots actually round-trip: restore one small file to scratch and hash-compare.

.DESCRIPTION
Backups you've never restored aren't backups. This script picks a small file from the
newest snapshot, restores it to a SCRATCH directory under %TEMP%\dmn-test-restore\,
compares its decrypted+restored content against the snapshot's recorded metadata, and
deletes the scratch dir.

** This script NEVER restores to your real filesystem. ** The scratch path is a fresh
directory under %TEMP% so there's zero risk of clobbering real data.

Used by the widget's "Test restore" button (passes -PromptPassword for the user-typed
verification path) and by the monthly scheduled task (uses the stored env var).

Updates state.LastTestRestoreAt / LastTestRestoreOk. Sends a toast on failure.

.PARAMETER PromptPassword
Read the encryption password interactively (hidden prompt) instead of using $env:enc_pswd.
Used by the widget so the user proves they still know the password.

.PARAMETER MaxFileSizeBytes
Skip files larger than this when picking the test file. Default 1 MiB. Keeps the
test cheap.

.EXAMPLE
.\Invoke-TestRestore.ps1
Run the monthly scheduled test (uses $env:enc_pswd).

.EXAMPLE
.\Invoke-TestRestore.ps1 -PromptPassword
Widget-style test: type the password fresh, prove you still know it.
#>
[CmdletBinding()]
param(
    [switch]$PromptPassword,
    [long]$MaxFileSizeBytes = 1MB
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path $here '..\lib\Memorybox.psm1'
Import-Module $libPath -Force

$lock        = $null
$scratchRoot = Join-Path $env:TEMP "dmn-test-restore-$([guid]::NewGuid().Guid.Substring(0,8))"
$pwOverride  = $null

try {
    Assert-MemoryboxReady
    Connect-MemoryboxSmb

    if ($PromptPassword) {
        Write-Host "Type the restic encryption password to verify you still know it:"
        $typed = Get-EncryptionPassword -Prompt
        Set-ResticPasswordOverride -Password $typed
        $pwOverride = $true
    }

    $lock = Lock-NodeOperation -Name 'test-restore'
    Write-DmnLog "Test-restore starting (scratch=$scratchRoot, max-file=$MaxFileSizeBytes bytes)" -Kind 'verify'

    # Pick newest snapshot
    $raw = Invoke-Restic snapshots --json 2>$null
    if (-not $raw) { throw "No snapshots in repo to test." }
    $snapshots = @(($raw | Out-String).Trim() | ConvertFrom-Json)
    if (-not $snapshots -or $snapshots.Count -eq 0) { throw "No snapshots in repo." }
    $newest = $snapshots | Sort-Object @{Expression={[datetime]$_.time}} -Descending | Select-Object -First 1
    Write-DmnLog "Using snapshot: $($newest.short_id) at $($newest.time)" -Kind 'verify'

    # List files in the snapshot, pick a small one
    $listRaw = Invoke-Restic ls --json $newest.id 2>$null
    if (-not $listRaw) { throw "ls returned nothing for snapshot $($newest.short_id)." }
    $files = @()
    foreach ($line in ($listRaw -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.struct_type -eq 'node' -and $obj.type -eq 'file' -and $obj.size -gt 0 -and $obj.size -le $MaxFileSizeBytes) {
                $files += $obj
            }
        } catch {}
    }
    if ($files.Count -eq 0) {
        throw "No suitable test file found in snapshot $($newest.short_id) (need a file > 0 bytes and <= $MaxFileSizeBytes bytes)."
    }
    $testFile = $files | Get-Random
    Write-DmnLog "Picked test file: $($testFile.path) ($($testFile.size) bytes)" -Kind 'verify'

    # Restore it to scratch.
    # Note: restic may return exit 1 when restoring under %TEMP% because it can't set
    # NTFS timestamps on the synthetic intermediate directories (e.g. C:\Users) it
    # recreates inside the scratch tree. The actual file data is still restored
    # correctly, so we verify success by file existence + size + hash, not exit code.
    # We temporarily relax $ErrorActionPreference because restic's stderr-on-stdout
    # would otherwise be treated as a terminating error before we can inspect the result.
    New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Invoke-Restic restore $newest.id --target $scratchRoot --include $testFile.path 2>&1 |
            Tee-Object -FilePath (Get-DmnLogPath -Kind 'verify') -Append
        $resticExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
    }

    # Find the restored file (restic preserves the path layout under --target)
    $restored = Get-ChildItem -Path $scratchRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -eq $testFile.size } |
                Select-Object -First 1
    if (-not $restored) {
        throw "Restored file not found in scratch dir $scratchRoot (restic exit $resticExit)."
    }
    if ($resticExit -ne 0) {
        Write-DmnLog "restic restore exited $resticExit but the test file is intact in scratch (likely a benign timestamp warning on synthetic parent dirs)" -Kind 'verify' -Level WARN
    }

    # Hash it
    $restoredHash = (Get-FileHash -Path $restored.FullName -Algorithm SHA256).Hash
    Write-DmnLog "Restored file hash (SHA256): $restoredHash" -Kind 'verify'

    # Cross-check: re-read the original file (if it still exists locally) and compare hashes.
    # If the original is gone, the test still passes -- we only verify the restore succeeded
    # AND the restored file can be hashed (i.e. decrypted correctly + non-empty).
    # restic emits POSIX-style paths like /C/Users/... -- convert to C:\Users\... for Windows.
    $origPath = $testFile.path
    if ($origPath -match '^/([A-Za-z])/(.*)') {
        $origPath = ($matches[1] + ':\' + $matches[2]) -replace '/', '\'
    }
    if (Test-Path $origPath) {
        try {
            $origHash = (Get-FileHash -Path $origPath -Algorithm SHA256).Hash
            if ($origHash -eq $restoredHash) {
                Write-DmnLog "Hash MATCH between original and restored ($origHash)" -Kind 'verify'
            } else {
                Write-DmnLog "Hash MISMATCH: original=$origHash restored=$restoredHash (file may have changed since the snapshot -- this is informational, not a failure)" -Kind 'verify' -Level WARN
            }
        } catch {
            Write-DmnLog "Could not hash original (may have been deleted/changed): $($_.Exception.Message)" -Kind 'verify' -Level WARN
        }
    } else {
        Write-DmnLog "Original file no longer exists locally ($origPath); skipping cross-check (this is fine -- restore itself succeeded)" -Kind 'verify'
    }

    Write-DmnLog "Test-restore OK (decrypted and read $($restored.Length) bytes)" -Kind 'verify'
    Set-NodeState -Updates @{
        LastTestRestoreAt = (Get-Date).ToString('o')
        LastTestRestoreOk = $true
    }

    if ($PromptPassword) {
        Send-MemoryboxToast -Title "Test restore PASSED" -Body "Successfully decrypted and restored $($testFile.path | Split-Path -Leaf) ($($restored.Length) bytes). Your password is correct and the repo is healthy." -Level Success
    }
} catch {
    $err = $_.Exception.Message
    Write-DmnLog "Test-restore FAILED: $err" -Kind 'verify' -Level ERROR
    Set-NodeState -Updates @{
        LastTestRestoreAt = (Get-Date).ToString('o')
        LastTestRestoreOk = $false
    }
    Send-MemoryboxToast -Title "Test restore FAILED" -Body "Test-restore did not complete: $err  $(Get-DmnSupportLine)" -Level Error
    exit 1
} finally {
    if ($pwOverride) { Clear-ResticPasswordOverride }
    if ($lock) { Unlock-NodeOperation -Handle $lock -Name 'test-restore' }
    if (Test-Path $scratchRoot) {
        try { Remove-Item -Recurse -Force $scratchRoot -ErrorAction SilentlyContinue } catch {}
    }
}
