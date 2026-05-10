<#
.SYNOPSIS
Diagnostic -- runs all the preflight probes and prints a checklist of what's working.

.DESCRIPTION
Verifies, in order:
  1. The MEMORYBOX_* env vars are set (HOST/PORT/USER/PASSWORD/NODE_NAME + enc_pswd)
  2. Node name is valid
  3. ICMP reachability of the host
  4. TCP reachability of the configured port
  5. HTTP response (and identifies the server as Synology if applicable)
  6. DSM API auth with the supplied credentials
  7. SMB shares accessible to the user
  8. Node directory state on the NAS
  9. restic is installed
 10. Restic repo is initialized and unlocks with $env:enc_pswd
 11. Backup targets are configured
 12. Scheduled tasks are registered

Exit code is 0 if everything passes, 1 otherwise. Safe to run anytime.

.EXAMPLE
.\Test-Setup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) 'lib\Memorybox.psm1'
Import-Module $libPath -Force

$failures = 0
function Check($label, $passed, $detail = '') {
    $tag = if ($passed) { '[OK]   ' } else { '[FAIL] ' }
    $color = if ($passed) { 'Green' } else { 'Red' }
    Write-Host "$tag$label" -ForegroundColor $color -NoNewline
    if ($detail) { Write-Host "  -- $detail" -ForegroundColor DarkGray } else { Write-Host '' }
    if (-not $passed) { $script:failures++ }
}

Write-Host ""
Write-Host "DesktopMemoryNode preflight" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan

# 1. Env vars
$cfg = Get-MemoryboxConfig
$missing = Get-MissingMemoryboxVars
Check "All required env vars set" ($missing.Count -eq 0) `
    "host=$($cfg.Host) port=$($cfg.Port) user=$($cfg.User) password=$(if ($cfg.HasPassword){'<set>'}else{'<missing>'}) node=$(if ($cfg.NodeName){$cfg.NodeName}else{'<missing>'}) enc_pswd=$(if ($cfg.HasEncPassword){'<set>'}else{'<missing>'})"

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing: $($missing -join ', ')." -ForegroundColor Yellow
    Write-Host "Run setup\Set-MemoryboxVars.ps1 (and set `$env:enc_pswd at User scope), then re-run this." -ForegroundColor Yellow
    exit 1
}

# 1b. Node name validity
$nameCheck = Test-MemoryboxNodeName -Name $cfg.NodeName -Detailed
Check "Node name '$($cfg.NodeName)' valid" $nameCheck.Valid $nameCheck.Reason

# 2-4. Connection
$conn = Test-MemoryboxConnection
Check "ICMP ping"            $conn.IcmpReachable
Check "TCP port $($cfg.Port)" $conn.TcpReachable
Check "HTTP $($cfg.BaseUrl)" ([bool]$conn.HttpStatus) "status=$($conn.HttpStatus) server=$($conn.ServerHeader)"
Check "Identifies as Synology" ([bool]$conn.IsSynology)

# 5. Auth
$auth = Test-MemoryboxAuth
Check "DSM API auth" $auth.Success $auth.Message

# 6. Shares
try {
    Connect-MemoryboxSmb
    $shares = Get-MemoryboxShares
    $writable = $shares | Where-Object { $_.Accessible }
    Check "SMB shares listable" ($shares.Count -gt 0) "$($shares.Count) shares, $($writable.Count) accessible"
    if ($writable) {
        Write-Host "       Accessible shares:" -ForegroundColor DarkGray
        $writable | ForEach-Object { Write-Host "         $($_.Path)" -ForegroundColor DarkGray }
    }
} catch {
    Check "SMB shares listable" $false $_.Exception.Message
}

# 6b. Node directory state on the NAS
try {
    $nodes = Get-MemoryboxNodes
    $thisNodeExists = [bool]($nodes | Where-Object { $_.NodeName -eq $cfg.NodeName })
    if ($thisNodeExists) {
        Check "Node dir on NAS ($($cfg.NodePath))" $true "exists (reusing)"
    } else {
        Check "Node dir on NAS ($($cfg.NodePath))" $true "does not exist yet (will be created on first backup)"
    }
    if ($nodes.Count -gt 0) {
        Write-Host "       Existing nodes on memorybox:" -ForegroundColor DarkGray
        $nodes | ForEach-Object {
            $tag = if ($_.NodeName -eq $cfg.NodeName) { ' (this machine)' } else { '' }
            Write-Host "         $($_.NodeName)$tag" -ForegroundColor DarkGray
        }
    }
} catch {
    Check "Node dir lookup" $false $_.Exception.Message
}

# 7. restic
$resticExe = $null
$cmd = Get-Command restic -ErrorAction SilentlyContinue
if ($cmd) {
    $resticExe = $cmd.Source
} else {
    $pkgRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    $candidate = Get-ChildItem $pkgRoot -Filter "restic.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $candidate) {
        $candidate = Get-ChildItem $pkgRoot -Filter "restic_*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($candidate) { $resticExe = $candidate.FullName }
}
if ($resticExe) {
    $ver = (& $resticExe version) -join ' '
    $onPath = [bool]$cmd
    $detail = "$ver$(if (-not $onPath) {' (installed but not on this shells PATH; new shell will pick it up)'})"
    Check "restic available" $true $detail
} else {
    Check "restic available" $false "not installed; run setup\Install-Restic.ps1"
}

# 8. Restic repo initialized
$repoConfigFile = Join-Path $cfg.ResticRepoPath 'config'
$repoExists = Test-Path $repoConfigFile
if ($repoExists) {
    $exit = Invoke-Restic snapshots --no-lock --quiet 2>&1 | Out-Null
    Check "Restic repo unlocks with `$env:enc_pswd" ($LASTEXITCODE -eq 0) "$($cfg.ResticRepoPath)"
} else {
    Check "Restic repo initialized" $false "no repo at $($cfg.ResticRepoPath); run setup\Initialize-ResticRepo.ps1"
}

# 9. Backup targets configured
$targetsPath = Get-DmnTargetsPath
$targetsExist = Test-Path $targetsPath
if ($targetsExist) {
    $t = Get-BackupTargets
    Check "Backup targets configured" ($t.include.Count -gt 0) "$($t.include.Count) include, $($t.exclude.Count) exclude"
} else {
    Check "Backup targets configured" $false "no targets.json; run setup\Set-BackupTargets.ps1"
}

# 10. Scheduled tasks
$scheduledTasks = Get-ScheduledTask -TaskPath '\DesktopMemoryNode\' -ErrorAction SilentlyContinue
$expected = @('Backup','Forget','Verify','TestRestore')
$present  = @($scheduledTasks | ForEach-Object { $_.TaskName })
$missingTasks = $expected | Where-Object { $_ -notin $present }
Check "Scheduled tasks installed" ($missingTasks.Count -eq 0) `
    $(if ($missingTasks.Count -eq 0) { "$(($scheduledTasks | Measure-Object).Count) tasks under \DesktopMemoryNode\" } else { "missing: $($missingTasks -join ', '); run setup\Install-Schedule.ps1" })

# 11. Last backup state (informational)
$state = Get-NodeState
if ($state.LastBackupAt) {
    $when = [datetime]$state.LastBackupAt
    $ago  = [int]((Get-Date) - $when).TotalHours
    $okMark = if ($state.LastBackupOk) { 'OK' } else { 'FAILED' }
    Write-Host "[INFO] Last backup: $when ($($ago)h ago) -- $okMark" -ForegroundColor DarkGray
} else {
    Write-Host "[INFO] No backups have run yet" -ForegroundColor DarkGray
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
