# Memorybox.psm1
# Reusable functions for interacting with the cloud memorybox (Synology NAS) from Windows.
#
# All connection details come from user-scoped environment variables:
#   MEMORYBOX_HOST, MEMORYBOX_PORT, MEMORYBOX_USER, MEMORYBOX_PASSWORD
# See shared/CONFIG.md for the naming convention.

function Get-MemoryboxConfig {
    <#
    .SYNOPSIS
    Returns memorybox connection config from user environment variables. Never returns the password.
    #>
    [CmdletBinding()]
    param()

    $h  = [Environment]::GetEnvironmentVariable("MEMORYBOX_HOST",      "User")
    $p  = [Environment]::GetEnvironmentVariable("MEMORYBOX_PORT",      "User")
    $u  = [Environment]::GetEnvironmentVariable("MEMORYBOX_USER",      "User")
    $pw = [Environment]::GetEnvironmentVariable("MEMORYBOX_PASSWORD",  "User")
    $n  = [Environment]::GetEnvironmentVariable("MEMORYBOX_NODE_NAME", "User")

    [PSCustomObject]@{
        Host        = $h
        Port        = $p
        User        = $u
        NodeName    = $n
        HasPassword = -not [string]::IsNullOrEmpty($pw)
        BaseUrl     = if ($h -and $p) { "http://${h}:${p}" } else { $null }
        NodePath    = if ($h -and $n) { "\\${h}\home\dmn-${n}" } else { $null }
        IsComplete  = ($h -and $p -and $u -and $pw -and $n)
    }
}

function Test-MemoryboxNodeName {
    <#
    .SYNOPSIS
    Validates a candidate node name against the naming rules. Returns $true / $false; -Detailed for explanation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Detailed
    )

    $pattern = '^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$'
    $ok = $Name -cmatch $pattern
    if ($Detailed) {
        [PSCustomObject]@{
            Name    = $Name
            Valid   = $ok
            Reason  = if ($ok) { 'ok' }
                      elseif ($Name.Length -lt 1 -or $Name.Length -gt 32) { 'must be 1-32 characters' }
                      elseif ($Name -cnotmatch '^[a-z0-9-]+$') { 'only lowercase letters, digits, hyphens allowed' }
                      elseif ($Name.StartsWith('-') -or $Name.EndsWith('-')) { 'must not start or end with a hyphen' }
                      else { 'invalid' }
        }
    } else {
        $ok
    }
}

function Get-MemoryboxNodes {
    <#
    .SYNOPSIS
    Lists existing node directories on the memorybox (i.e. dmn-* under \\host\home).
    Requires that an SMB session is established (run Connect-MemoryboxSmb first).
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    if (-not $cfg.Host) { throw "MEMORYBOX_HOST not set." }

    $homePath = "\\$($cfg.Host)\home"
    if (-not (Test-Path $homePath)) {
        throw "Cannot reach $homePath. Run Connect-MemoryboxSmb first."
    }

    Get-ChildItem -Path $homePath -Directory -Filter 'dmn-*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            [PSCustomObject]@{
                NodeName = $_.Name -replace '^dmn-',''
                Path     = $_.FullName
                Created  = $_.CreationTime
            }
        }
}

function Test-MemoryboxNodeNameAvailable {
    <#
    .SYNOPSIS
    Checks whether a candidate node name is free on the memorybox (no dmn-<name> dir exists).
    Returns an object with Available + Conflict info.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    Connect-MemoryboxSmb
    $cfg = Get-MemoryboxConfig
    $candidatePath = "\\$($cfg.Host)\home\dmn-$Name"
    $exists = Test-Path $candidatePath
    [PSCustomObject]@{
        Name      = $Name
        Available = -not $exists
        Path      = $candidatePath
        Existing  = if ($exists) { (Get-Item $candidatePath).CreationTime } else { $null }
    }
}

function Get-MemoryboxCredential {
    <#
    .SYNOPSIS
    Returns a PSCredential built from MEMORYBOX_USER / MEMORYBOX_PASSWORD. Throws if either is unset.
    #>
    [CmdletBinding()]
    param()

    $u  = [Environment]::GetEnvironmentVariable("MEMORYBOX_USER",     "User")
    $pw = [Environment]::GetEnvironmentVariable("MEMORYBOX_PASSWORD", "User")
    if (-not $u -or -not $pw) {
        throw "MEMORYBOX_USER or MEMORYBOX_PASSWORD not set. Run setup/Set-MemoryboxVars.ps1."
    }
    $secure = ConvertTo-SecureString $pw -AsPlainText -Force
    [System.Management.Automation.PSCredential]::new($u, $secure)
}

function Test-MemoryboxConnection {
    <#
    .SYNOPSIS
    Probes ICMP, TCP, and HTTP reachability of the memorybox. Returns a status object; never throws.
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    $result = [PSCustomObject]@{
        Host          = $cfg.Host
        Port          = $cfg.Port
        ConfigOk      = $true
        IcmpReachable = $null
        TcpReachable  = $null
        HttpStatus    = $null
        ServerHeader  = $null
        IsSynology    = $null
        ErrorDetail   = $null
    }

    if (-not $cfg.Host -or -not $cfg.Port) {
        $result.ConfigOk    = $false
        $result.ErrorDetail = "MEMORYBOX_HOST or MEMORYBOX_PORT not set."
        return $result
    }

    try { $result.IcmpReachable = Test-Connection -ComputerName $cfg.Host -Count 1 -Quiet -ErrorAction Stop }
    catch { $result.IcmpReachable = $false }

    try {
        $tnc = Test-NetConnection -ComputerName $cfg.Host -Port $cfg.Port -WarningAction SilentlyContinue
        $result.TcpReachable = $tnc.TcpTestSucceeded
    } catch { $result.TcpReachable = $false }

    if ($result.TcpReachable) {
        try {
            $r = Invoke-WebRequest -Uri "$($cfg.BaseUrl)/" -Method Get -TimeoutSec 15 -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
            $result.HttpStatus   = $r.StatusCode
            $result.ServerHeader = $r.Headers['Server']
            $result.IsSynology   = [bool]($r.Content -match 'Synology')
        } catch {
            $resp = $_.Exception.Response
            if ($resp) {
                $result.HttpStatus   = [int]$resp.StatusCode
                $result.ServerHeader = $resp.Headers['Server']
            }
            $result.ErrorDetail = $_.Exception.Message
        }
    }

    $result
}

function Test-MemoryboxAuth {
    <#
    .SYNOPSIS
    Verifies the MEMORYBOX_USER / MEMORYBOX_PASSWORD work against DSM's auth API. Logs out immediately.
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    if (-not $cfg.IsComplete) {
        return [PSCustomObject]@{ Success = $false; Message = "Config incomplete. Run Set-MemoryboxVars.ps1." }
    }

    $pw = [Environment]::GetEnvironmentVariable("MEMORYBOX_PASSWORD", "User")
    $body = @{
        api     = 'SYNO.API.Auth'
        version = '3'
        method  = 'login'
        account = $cfg.User
        passwd  = $pw
        session = 'Default'
        format  = 'sid'
    }
    $pw = $null

    try {
        $r = Invoke-RestMethod -Uri "$($cfg.BaseUrl)/webapi/auth.cgi" -Method Post -Body $body -TimeoutSec 15
        if ($r.success) {
            $sid = $r.data.sid
            try { Invoke-RestMethod -Uri "$($cfg.BaseUrl)/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=logout&_sid=$sid" -TimeoutSec 5 | Out-Null } catch {}
            return [PSCustomObject]@{ Success = $true; Message = "DSM auth OK as $($cfg.User)" }
        }
        return [PSCustomObject]@{ Success = $false; Message = "DSM login failed (error code $($r.error.code))" }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "DSM login HTTP error: $($_.Exception.Message)" }
    }
}

function Get-MemoryboxShares {
    <#
    .SYNOPSIS
    Lists SMB shares on the memorybox and tests accessibility from the current user.
    Requires that the current SMB session has authenticated with MEMORYBOX_USER (e.g. via `net use`).
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    if (-not $cfg.Host) { throw "MEMORYBOX_HOST not set." }

    $raw = & cmd /c "net view \\$($cfg.Host) /all" 2>&1
    $shares = @()
    foreach ($line in $raw) {
        if ($line -match '^(\S+)\s+Disk') {
            $name = $matches[1]
            $unc  = "\\$($cfg.Host)\$name"
            $shares += [PSCustomObject]@{
                Name       = $name
                Path       = $unc
                Accessible = [bool](Test-Path $unc -ErrorAction SilentlyContinue)
            }
        }
    }
    $shares
}

function Connect-MemoryboxSmb {
    <#
    .SYNOPSIS
    Authenticates an SMB session to the memorybox using the configured credentials.
    Idempotent — if a session already exists, this is a no-op.
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    if (-not $cfg.IsComplete) { throw "Config incomplete. Run Set-MemoryboxVars.ps1." }

    $existing = Get-SmbMapping -RemotePath "\\$($cfg.Host)\IPC$" -ErrorAction SilentlyContinue
    if ($existing) { return }

    $pw = [Environment]::GetEnvironmentVariable("MEMORYBOX_PASSWORD", "User")
    & cmd /c "net use \\$($cfg.Host)\IPC`$ /user:$($cfg.User) $pw" 2>&1 | Out-Null
    $pw = $null
}

Export-ModuleMember -Function `
    Get-MemoryboxConfig, `
    Get-MemoryboxCredential, `
    Test-MemoryboxConnection, `
    Test-MemoryboxAuth, `
    Get-MemoryboxShares, `
    Connect-MemoryboxSmb, `
    Test-MemoryboxNodeName, `
    Get-MemoryboxNodes, `
    Test-MemoryboxNodeNameAvailable
