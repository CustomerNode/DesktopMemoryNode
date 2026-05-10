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
Check "Env vars set (HOST/PORT/USER/PASSWORD)" $cfg.IsComplete `
    "host=$($cfg.Host) port=$($cfg.Port) user=$($cfg.User) password=$(if ($cfg.HasPassword){'<set>'}else{'<missing>'})"

if (-not $cfg.IsComplete) {
    Write-Host ""
    Write-Host "Run setup\Set-MemoryboxVars.ps1 to fill in missing values, then re-run this." -ForegroundColor Yellow
    exit 1
}

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

# 7. restic
$restic = Get-Command restic -ErrorAction SilentlyContinue
Check "restic on PATH" ([bool]$restic) $(if ($restic) { (& restic version) -join ' ' } else { 'not installed; run setup\Install-Restic.ps1' })

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
