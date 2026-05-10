<#
.SYNOPSIS
Diagnostic — runs all the preflight probes and prints a checklist of what's working.

.DESCRIPTION
Verifies, in order:
  1. The MEMORYBOX_* env vars are set
  2. ICMP reachability of the host
  3. TCP reachability of the configured port
  4. HTTP response (and identifies the server as Synology if applicable)
  5. DSM API auth with the supplied credentials
  6. SMB shares accessible to the user
  7. restic is installed

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
Check "Env vars set (HOST/PORT/USER/PASSWORD/NODE_NAME)" $cfg.IsComplete `
    "host=$($cfg.Host) port=$($cfg.Port) user=$($cfg.User) password=$(if ($cfg.HasPassword){'<set>'}else{'<missing>'}) node=$(if ($cfg.NodeName){$cfg.NodeName}else{'<missing>'})"

if (-not $cfg.IsComplete) {
    Write-Host ""
    Write-Host "Run setup\Set-MemoryboxVars.ps1 to fill in missing values, then re-run this." -ForegroundColor Yellow
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

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
