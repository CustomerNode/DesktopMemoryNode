# Memorybox.psm1
# Reusable PowerShell module for the DesktopMemoryNode Windows agent.
#
# Connection details and the encryption password come from user-scoped environment
# variables (see shared/CONFIG.md):
#   MEMORYBOX_HOST, MEMORYBOX_PORT, MEMORYBOX_USER, MEMORYBOX_PASSWORD,
#   MEMORYBOX_NODE_NAME, enc_pswd
#
# Local state (config files, logs, locks) lives under %LOCALAPPDATA%\DesktopMemoryNode\.

# --------------------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------------------

$script:RequiredConnectionVars = @(
    'MEMORYBOX_HOST',
    'MEMORYBOX_PORT',
    'MEMORYBOX_USER',
    'MEMORYBOX_PASSWORD',
    'MEMORYBOX_NODE_NAME'
)

$script:RequiredEncryptionVar = 'enc_pswd'

# Display / personalization config (optional). See shared/CONFIG.md.
$script:DisplayNameVar    = 'DMN_DISPLAY_NAME'    # e.g. "Mom" -- the user this machine belongs to
$script:TechNameVar       = 'DMN_TECH_NAME'       # e.g. "Sam" -- person to contact when things go wrong
$script:TechContactVar    = 'DMN_TECH_CONTACT'    # e.g. "sam@example.com" or "(555) 123-4567"

# --------------------------------------------------------------------------------------
# State directory layout
# --------------------------------------------------------------------------------------

function Get-DmnStateRoot {
    <#
    .SYNOPSIS
    Returns the DesktopMemoryNode local state directory, creating it if missing.
    Layout: targets.json, state.json, locks/, logs/.
    #>
    [CmdletBinding()]
    param()

    $root = Join-Path $env:LOCALAPPDATA 'DesktopMemoryNode'
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    foreach ($sub in 'locks', 'logs') {
        $p = Join-Path $root $sub
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    $root
}

function Get-DmnTargetsPath { Join-Path (Get-DmnStateRoot) 'targets.json' }
function Get-DmnStatePath   { Join-Path (Get-DmnStateRoot) 'state.json' }
function Get-DmnLockPath    { param([string]$Name = 'backup') Join-Path (Get-DmnStateRoot) "locks\$Name.lock" }
function Get-DmnLogPath {
    param([string]$Kind = 'backup', [datetime]$Date = (Get-Date))
    Join-Path (Get-DmnStateRoot) ("logs\{0}-{1:yyyy-MM-dd}.log" -f $Kind, $Date)
}

# --------------------------------------------------------------------------------------
# Connection config (env vars)
# --------------------------------------------------------------------------------------

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
    $e  = [Environment]::GetEnvironmentVariable($script:RequiredEncryptionVar, "User")

    [PSCustomObject]@{
        Host             = $h
        Port             = $p
        User             = $u
        NodeName         = $n
        HasPassword      = -not [string]::IsNullOrEmpty($pw)
        HasEncPassword   = -not [string]::IsNullOrEmpty($e)
        BaseUrl          = if ($h -and $p) { "http://${h}:${p}" } else { $null }
        NodePath         = if ($h -and $n) { "\\${h}\home\dmn-${n}" } else { $null }
        ResticRepoPath   = if ($h -and $n) { "\\${h}\home\dmn-${n}\restic-repo" } else { $null }
        IsComplete       = ($h -and $p -and $u -and $pw -and $n -and $e)
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

function Get-DmnDisplayConfig {
    <#
    .SYNOPSIS
    Returns optional personalization values used by the user-facing UI.
    All fields are optional; UI must handle null/empty gracefully.

    Fields:
      UserName       - Display name to greet on this machine (e.g. "Mom").
                       Empty -> UI uses generic phrasing.
      TechName       - Person to contact for help (e.g. "Sam").
                       Empty -> UI says "tech support".
      TechContact    - Phone or email for tech support (e.g. "sam@example.com").
                       Empty -> UI shows TechName only.
    #>
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        UserName    = [Environment]::GetEnvironmentVariable($script:DisplayNameVar, 'User')
        TechName    = [Environment]::GetEnvironmentVariable($script:TechNameVar,    'User')
        TechContact = [Environment]::GetEnvironmentVariable($script:TechContactVar, 'User')
    }
}

function Get-DmnSupportLine {
    <#
    .SYNOPSIS
    Returns a one-line "need help?" string for use in toasts and forms.
    #>
    [CmdletBinding()]
    param()

    $d = Get-DmnDisplayConfig
    $name = if ($d.TechName) { $d.TechName } else { 'tech support' }
    if ($d.TechContact) { "Need help? Contact $name at $($d.TechContact)." }
    else                { "Need help? Contact $name." }
}

function Get-MissingMemoryboxVars {
    <#
    .SYNOPSIS
    Returns the names of any required env vars that are missing or empty. Empty list = all good.
    #>
    [CmdletBinding()]
    param()

    $missing = @()
    foreach ($v in $script:RequiredConnectionVars) {
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($v, 'User'))) { $missing += $v }
    }
    if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($script:RequiredEncryptionVar, 'User'))) {
        $missing += $script:RequiredEncryptionVar
    }
    $missing
}

function Assert-MemoryboxReady {
    <#
    .SYNOPSIS
    Verifies all required env vars are set. If anything is missing, sends a toast and throws.
    Use at the top of every agent script (backup, forget, verify, test-restore).
    #>
    [CmdletBinding()]
    param()

    $missing = Get-MissingMemoryboxVars
    if ($missing.Count -eq 0) { return }

    $support = Get-DmnSupportLine
    $msg = "Missing required env var(s): $($missing -join ', '). $support"
    try { Send-MemoryboxToast -Title "Memory Box: configuration error" -Body $msg -Level Error } catch {}
    throw $msg
}

# --------------------------------------------------------------------------------------
# Encryption password
# --------------------------------------------------------------------------------------

function Get-EncryptionPassword {
    <#
    .SYNOPSIS
    Returns the restic encryption password. Default reads from $env:enc_pswd (User scope);
    -Prompt forces an interactive hidden prompt instead, used by the widget's verify-restore flow
    so the user proves they still know the password (not just that the disk has it).

    .PARAMETER Prompt
    Always ask interactively, ignoring the stored env var.

    .PARAMETER Confirm
    With -Prompt, ask twice and require the two entries to match.
    #>
    [CmdletBinding()]
    param(
        [switch]$Prompt,
        [switch]$Confirm
    )

    if (-not $Prompt) {
        $stored = [Environment]::GetEnvironmentVariable($script:RequiredEncryptionVar, 'User')
        if ($stored) { return $stored }
        # Fall through to prompt if env var missing -- caller may be a setup script.
    }

    $secure = Read-Host "Encryption password" -AsSecureString
    $value  = [System.Net.NetworkCredential]::new("", $secure).Password
    if ($Confirm) {
        $secure2 = Read-Host "Encryption password (confirm)" -AsSecureString
        $value2  = [System.Net.NetworkCredential]::new("", $secure2).Password
        if ($value -cne $value2) { throw "Passwords do not match." }
    }
    $value
}

# --------------------------------------------------------------------------------------
# Toast notifications (works with or without BurntToast)
# --------------------------------------------------------------------------------------

function Send-MemoryboxToast {
    <#
    .SYNOPSIS
    Sends a sticky Windows toast notification that stays visible until the user dismisses it.

    .DESCRIPTION
    Uses BurntToast's `Reminder` scenario (toast stays on screen until clicked) with a
    Dismiss button. If BurntToast isn't installed, falls back to a NotifyIcon balloon
    (auto-dismisses after 15s -- best-effort until BurntToast is installed in Phase 4 setup).
    Never throws: toast failure must not break the calling script.

    .PARAMETER Title
    Short headline. Will be prefixed with "DesktopMemoryNode" if not already.

    .PARAMETER Body
    Body text.

    .PARAMETER Level
    Info | Success | Warning | Error. Affects icon for the fallback path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [ValidateSet('Info','Success','Warning','Error')][string]$Level = 'Info'
    )

    if ($Title -notmatch '^DesktopMemoryNode') { $Title = "DesktopMemoryNode: $Title" }

    if (Get-Module -ListAvailable -Name BurntToast) {
        try {
            Import-Module BurntToast -ErrorAction Stop

            $text1   = New-BTText -Text $Title
            $text2   = New-BTText -Text $Body
            $binding = New-BTBinding -Children $text1, $text2
            $visual  = New-BTVisual -BindingGeneric $binding

            $dismissBtn = New-BTButton -Content 'Dismiss' -Dismiss
            $actions    = New-BTAction -Buttons $dismissBtn

            $content = New-BTContent -Visual $visual -Actions $actions -Scenario Reminder
            Submit-BTNotification -Content $content
            return
        } catch {}
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = switch ($Level) {
            'Error'   { [System.Windows.Forms.ToolTipIcon]::Error }
            'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
            default   { [System.Windows.Forms.ToolTipIcon]::Info }
        }
        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.SystemIcons]::Information
        $balloon.BalloonTipIcon  = $icon
        $balloon.BalloonTipTitle = $Title
        $balloon.BalloonTipText  = $Body
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(15000)
        Start-Sleep -Milliseconds 200
    } catch {}
}

# --------------------------------------------------------------------------------------
# Node identity & naming
# --------------------------------------------------------------------------------------

function Test-MemoryboxNodeName {
    <#
    .SYNOPSIS
    Validates a candidate node name. Returns $true / $false; -Detailed for explanation.
    Rules: lowercase letters, digits, hyphens; 1-32 chars; no leading/trailing hyphen.
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
            Name   = $Name
            Valid  = $ok
            Reason = if ($ok) { 'ok' }
                     elseif ($Name.Length -lt 1 -or $Name.Length -gt 32) { 'must be 1-32 characters' }
                     elseif ($Name -cnotmatch '^[a-z0-9-]+$') { 'only lowercase letters, digits, hyphens allowed' }
                     elseif ($Name.StartsWith('-') -or $Name.EndsWith('-')) { 'must not start or end with a hyphen' }
                     else { 'invalid' }
        }
    } else { $ok }
}

function Get-MemoryboxNodes {
    <#
    .SYNOPSIS
    Lists existing node directories on the memorybox (dmn-* under \\host\home).
    Requires an SMB session -- call Connect-MemoryboxSmb first.
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
    Checks whether a candidate node name is free on the memorybox. Returns Available + Existing dir info.
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

# --------------------------------------------------------------------------------------
# Network probes
# --------------------------------------------------------------------------------------

function Test-MemoryboxConnection {
    <#
    .SYNOPSIS
    Probes ICMP, TCP, and HTTP reachability of the memorybox. Returns a status object; never throws.
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    $result = [PSCustomObject]@{
        Host = $cfg.Host; Port = $cfg.Port; ConfigOk = $true
        IcmpReachable = $null; TcpReachable = $null
        HttpStatus = $null; ServerHeader = $null; IsSynology = $null
        ErrorDetail = $null
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
    Verifies MEMORYBOX_USER / MEMORYBOX_PASSWORD against DSM's auth API. Logs out immediately.
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    if (-not $cfg.Host -or -not $cfg.Port -or -not $cfg.User -or -not $cfg.HasPassword) {
        return [PSCustomObject]@{ Success = $false; Message = "Connection config incomplete. Run Set-MemoryboxVars.ps1." }
    }

    $pw = [Environment]::GetEnvironmentVariable("MEMORYBOX_PASSWORD", "User")
    $body = @{
        api='SYNO.API.Auth'; version='3'; method='login'
        account=$cfg.User; passwd=$pw; session='Default'; format='sid'
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

# --------------------------------------------------------------------------------------
# SMB
# --------------------------------------------------------------------------------------

function Get-MemoryboxShares {
    <#
    .SYNOPSIS
    Lists SMB shares on the memorybox and tests accessibility.
    Requires an SMB session -- call Connect-MemoryboxSmb first.
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
    Authenticates an SMB session to the memorybox using configured credentials. Idempotent.
    #>
    [CmdletBinding()]
    param()

    $cfg = Get-MemoryboxConfig
    if (-not $cfg.Host -or -not $cfg.User -or -not $cfg.HasPassword) {
        throw "Connection config incomplete. Run Set-MemoryboxVars.ps1."
    }

    $existing = Get-SmbMapping -RemotePath "\\$($cfg.Host)\IPC$" -ErrorAction SilentlyContinue
    if ($existing) { return }

    $pw = [Environment]::GetEnvironmentVariable("MEMORYBOX_PASSWORD", "User")
    & cmd /c "net use \\$($cfg.Host)\IPC`$ /user:$($cfg.User) $pw" 2>&1 | Out-Null
    $pw = $null
}

# --------------------------------------------------------------------------------------
# restic binary discovery & wrapper
# --------------------------------------------------------------------------------------

function Get-ResticBinary {
    <#
    .SYNOPSIS
    Locates the restic executable. Checks PATH first; falls back to the winget portable
    install dir (where the bundled binary may not have been aliased to restic.exe).
    Throws if not found.
    #>
    [CmdletBinding()]
    param()

    $cmd = Get-Command restic -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $pkgRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $pkgRoot) {
        $shim = Get-ChildItem $pkgRoot -Filter 'restic.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($shim) { return $shim.FullName }

        $versioned = Get-ChildItem $pkgRoot -Filter 'restic_*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($versioned) {
            $alias = Join-Path (Split-Path -Parent $versioned.FullName) 'restic.exe'
            if (-not (Test-Path $alias)) { Copy-Item $versioned.FullName $alias -Force }
            return $alias
        }
    }

    throw "restic not found. Run setup\Install-Restic.ps1."
}

$script:ResticPasswordOverride = $null

function Set-ResticPasswordOverride {
    <#
    .SYNOPSIS
    Sets a session-scoped password to use instead of $env:enc_pswd for subsequent Invoke-Restic calls.
    Used by the tray widget's verify-restore flow so the user types the password fresh -- proving
    they still know it, not just that this disk has it. Always pair with Clear-ResticPasswordOverride.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Password)
    $script:ResticPasswordOverride = $Password
}

function Clear-ResticPasswordOverride {
    <#
    .SYNOPSIS
    Clears any password override set by Set-ResticPasswordOverride.
    #>
    $script:ResticPasswordOverride = $null
}

function Invoke-Restic {
    <#
    .SYNOPSIS
    Runs restic with RESTIC_REPOSITORY and RESTIC_PASSWORD populated from env/config.
    Forwards all arguments to restic via the automatic $args. Caller checks $LASTEXITCODE.

    Password source: the override set by Set-ResticPasswordOverride if any, otherwise
    $env:enc_pswd. Widget's verify-restore flow uses the override.

    .EXAMPLE
    Invoke-Restic init
    Invoke-Restic snapshots --json
    Invoke-Restic backup --tag scheduled C:\foo
    #>
    Assert-MemoryboxReady

    $cfg = Get-MemoryboxConfig
    $exe = Get-ResticBinary
    $password = if ($script:ResticPasswordOverride) { $script:ResticPasswordOverride } else { Get-EncryptionPassword }

    $oldRepo = $env:RESTIC_REPOSITORY
    $oldPw   = $env:RESTIC_PASSWORD
    try {
        $env:RESTIC_REPOSITORY = $cfg.ResticRepoPath
        $env:RESTIC_PASSWORD   = $password
        & $exe @args
    } finally {
        $env:RESTIC_REPOSITORY = $oldRepo
        $env:RESTIC_PASSWORD   = $oldPw
    }
}

# --------------------------------------------------------------------------------------
# Backup targets config
# --------------------------------------------------------------------------------------

function Get-DefaultBackupTargets {
    <#
    .SYNOPSIS
    Returns the default backup-targets config: include user data, exclude caches and OS junk.
    #>
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        include = @(
            (Join-Path $env:USERPROFILE 'Documents'),
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:USERPROFILE 'Pictures'),
            (Join-Path $env:USERPROFILE 'Videos'),
            (Join-Path $env:USERPROFILE 'Music'),
            (Join-Path $env:USERPROFILE 'Downloads')
        )
        exclude = @(
            '**/node_modules',
            '**/.cache',
            '**/__pycache__',
            '**/Thumbs.db',
            '**/.DS_Store',
            '**/desktop.ini',
            '**/*.tmp',
            '**/$RECYCLE.BIN',
            '**/System Volume Information',
            (Join-Path $env:USERPROFILE 'AppData')
        )
    }
}

function Get-BackupTargets {
    <#
    .SYNOPSIS
    Reads backup targets from targets.json, falling back to defaults if missing.
    #>
    [CmdletBinding()]
    param()

    $path = Get-DmnTargetsPath
    if (-not (Test-Path $path)) { return Get-DefaultBackupTargets }

    try {
        $raw = Get-Content -Raw -Path $path | ConvertFrom-Json
        [PSCustomObject]@{
            include = @($raw.include)
            exclude = @($raw.exclude)
        }
    } catch {
        Write-Warning "targets.json is malformed; falling back to defaults. ($($_.Exception.Message))"
        Get-DefaultBackupTargets
    }
}

function Set-BackupTargets {
    <#
    .SYNOPSIS
    Writes backup targets to targets.json. Validates that include is non-empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Include,
        [string[]]$Exclude = @()
    )

    if ($Include.Count -eq 0) { throw "Include list must contain at least one path." }
    $obj  = [PSCustomObject]@{ include = $Include; exclude = $Exclude }
    $json = $obj | ConvertTo-Json -Depth 5
    $path = Get-DmnTargetsPath
    $tmp  = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $json, [Text.Encoding]::UTF8)
    Move-Item -Force $tmp $path
}

# --------------------------------------------------------------------------------------
# Node state (last backup time, last verify, etc.)
# --------------------------------------------------------------------------------------

function Get-NodeState {
    <#
    .SYNOPSIS
    Reads the node state object from state.json. Returns a default object if missing.
    #>
    [CmdletBinding()]
    param()

    $path = Get-DmnStatePath
    $default = [PSCustomObject]@{
        LastBackupAt      = $null
        LastBackupOk      = $null
        LastBackupError   = $null
        LastVerifyAt      = $null
        LastVerifyOk      = $null
        LastTestRestoreAt = $null
        LastTestRestoreOk = $null
        SnapshotCount     = $null
        RepoSizeBytes     = $null
        WelcomeShown      = $false
    }
    if (-not (Test-Path $path)) { return $default }
    try {
        $raw = Get-Content -Raw -Path $path | ConvertFrom-Json
        foreach ($p in $default.PSObject.Properties.Name) {
            if ($raw.PSObject.Properties.Name -contains $p) { $default.$p = $raw.$p }
        }
        $default
    } catch { $default }
}

function Set-NodeState {
    <#
    .SYNOPSIS
    Atomically updates state.json with the supplied property values (merged with existing).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Updates)

    $current = Get-NodeState
    foreach ($k in $Updates.Keys) { $current.$k = $Updates[$k] }
    $json = $current | ConvertTo-Json -Depth 5
    $path = Get-DmnStatePath
    $tmp  = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $json, [Text.Encoding]::UTF8)
    Move-Item -Force $tmp $path
}

# --------------------------------------------------------------------------------------
# Lock files
# --------------------------------------------------------------------------------------

function Lock-NodeOperation {
    <#
    .SYNOPSIS
    Acquires an exclusive lock for the named operation. Returns a [System.IO.FileStream]
    handle which MUST be passed to Unlock-NodeOperation when done. Throws if already held.
    #>
    [CmdletBinding()]
    param([string]$Name = 'backup')

    $path = Get-DmnLockPath -Name $Name
    try {
        $fs = [System.IO.File]::Open($path, 'OpenOrCreate', 'Write', 'None')
        $bytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID at=$(Get-Date -Format o)`n")
        $fs.SetLength(0)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        return $fs
    } catch {
        throw "Could not acquire lock '$Name' at $path. Another run may be in progress. ($($_.Exception.Message))"
    }
}

function Unlock-NodeOperation {
    <#
    .SYNOPSIS
    Releases a lock acquired by Lock-NodeOperation. Idempotent.
    #>
    [CmdletBinding()]
    param([System.IO.FileStream]$Handle, [string]$Name = 'backup')

    if ($Handle) { try { $Handle.Dispose() } catch {} }
    $path = Get-DmnLockPath -Name $Name
    if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------------------

function Write-DmnLog {
    <#
    .SYNOPSIS
    Appends a timestamped line to the per-day log for the given Kind, and echoes it to the host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Kind = 'backup',
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = "{0:yyyy-MM-ddTHH:mm:sszzz} {1,-5} {2}" -f (Get-Date), $Level, $Message
    $path = Get-DmnLogPath -Kind $Kind
    Add-Content -Path $path -Value $line -Encoding UTF8
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

# --------------------------------------------------------------------------------------
# Exports
# --------------------------------------------------------------------------------------

Export-ModuleMember -Function `
    Get-DmnStateRoot, Get-DmnTargetsPath, Get-DmnStatePath, Get-DmnLockPath, Get-DmnLogPath, `
    Get-MemoryboxConfig, Get-MemoryboxCredential, `
    Get-MissingMemoryboxVars, Assert-MemoryboxReady, `
    Get-DmnDisplayConfig, Get-DmnSupportLine, `
    Get-EncryptionPassword, `
    Send-MemoryboxToast, `
    Test-MemoryboxNodeName, Get-MemoryboxNodes, Test-MemoryboxNodeNameAvailable, `
    Test-MemoryboxConnection, Test-MemoryboxAuth, `
    Get-MemoryboxShares, Connect-MemoryboxSmb, `
    Get-ResticBinary, Invoke-Restic, Set-ResticPasswordOverride, Clear-ResticPasswordOverride, `
    Get-DefaultBackupTargets, Get-BackupTargets, Set-BackupTargets, `
    Get-NodeState, Set-NodeState, `
    Lock-NodeOperation, Unlock-NodeOperation, `
    Write-DmnLog
