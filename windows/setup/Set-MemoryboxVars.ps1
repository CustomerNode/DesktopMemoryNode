<#
.SYNOPSIS
Sets the MEMORYBOX_* user environment variables that point at the cloud memorybox
and identify this node.

.DESCRIPTION
By default, only prompts for variables that aren't already set. Use -Force to re-prompt
for everything. Use -Show to display current state without changing anything.

The password is read via a hidden prompt (Read-Host -AsSecureString) and never echoed.
All variables are stored at User scope (no admin required).

The node name is validated against the naming convention (lowercase, digits, hyphens,
1-32 chars) and checked for conflicts against existing nodes on the memorybox. Use
-Reuse to skip the conflict check (e.g. when reinstalling on the same machine).

.EXAMPLE
.\Set-MemoryboxVars.ps1
Prompts only for missing values.

.EXAMPLE
.\Set-MemoryboxVars.ps1 -Force
Re-prompts for every value.

.EXAMPLE
.\Set-MemoryboxVars.ps1 -Show
Prints current state (password masked).

.EXAMPLE
.\Set-MemoryboxVars.ps1 -Force -Reuse
Re-prompts everything but allows the node name to match an existing dmn-<name> dir on the NAS.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Show,
    [switch]$Reuse
)

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) 'lib\Memorybox.psm1'
Import-Module $libPath -Force

$vars = @(
    @{ Name = 'MEMORYBOX_HOST';      Prompt = 'MEMORYBOX_HOST (IP or hostname)'; Secret = $false },
    @{ Name = 'MEMORYBOX_PORT';      Prompt = 'MEMORYBOX_PORT';                  Secret = $false },
    @{ Name = 'MEMORYBOX_USER';      Prompt = 'MEMORYBOX_USER';                  Secret = $false },
    @{ Name = 'MEMORYBOX_PASSWORD';  Prompt = 'MEMORYBOX_PASSWORD';              Secret = $true  },
    @{ Name = 'MEMORYBOX_NODE_NAME'; Prompt = 'MEMORYBOX_NODE_NAME (e.g. kitchen, office, laptop)'; Secret = $false; Validator = 'NodeName' }
)

if ($Show) {
    Write-Host ""
    Write-Host "Current memorybox env vars (User scope):" -ForegroundColor Cyan
    foreach ($v in $vars) {
        $val = [Environment]::GetEnvironmentVariable($v.Name, "User")
        $display = if ($v.Secret) {
            if ([string]::IsNullOrEmpty($val)) { '<not set>' } else { '<set>' }
        } else {
            if ([string]::IsNullOrEmpty($val)) { '<not set>' } else { $val }
        }
        "  {0,-22} = {1}" -f $v.Name, $display | Write-Host
    }
    Write-Host ""
    return
}

function Read-NodeName {
    param([string]$Prompt, [switch]$Reuse)
    while ($true) {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "    (empty input — skipping)" -ForegroundColor Yellow
            return $null
        }
        $value = $value.Trim().ToLower()

        $check = Test-MemoryboxNodeName -Name $value -Detailed
        if (-not $check.Valid) {
            Write-Host "    Invalid: $($check.Reason). Try again." -ForegroundColor Red
            continue
        }

        if (-not $Reuse) {
            try {
                $avail = Test-MemoryboxNodeNameAvailable -Name $value
                if (-not $avail.Available) {
                    Write-Host "    CONFLICT: a node named '$value' already exists on the memorybox" -ForegroundColor Red
                    Write-Host "    (created $($avail.Existing) at $($avail.Path))" -ForegroundColor DarkGray
                    Write-Host "    Pick a different name, or re-run with -Reuse to claim this name (e.g. reinstalling on the same machine)." -ForegroundColor Yellow
                    continue
                }
            } catch {
                Write-Host "    (couldn't check for conflicts: $($_.Exception.Message))" -ForegroundColor DarkGray
                Write-Host "    Proceeding anyway — verify manually that '$value' is unique." -ForegroundColor DarkGray
            }
        }
        return $value
    }
}

$changed = 0
foreach ($v in $vars) {
    $existing = [Environment]::GetEnvironmentVariable($v.Name, "User")
    $needPrompt = $Force -or [string]::IsNullOrEmpty($existing)
    if (-not $needPrompt) {
        Write-Host "  $($v.Name): already set, skipping (use -Force to overwrite)" -ForegroundColor DarkGray
        continue
    }

    if ($v.Validator -eq 'NodeName') {
        $value = Read-NodeName -Prompt $v.Prompt -Reuse:$Reuse
    } elseif ($v.Secret) {
        $secure = Read-Host $v.Prompt -AsSecureString
        $value  = [System.Net.NetworkCredential]::new("", $secure).Password
        $secure = $null
    } else {
        $value = Read-Host $v.Prompt
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host "  $($v.Name): empty input, skipping" -ForegroundColor Yellow
        continue
    }

    [Environment]::SetEnvironmentVariable($v.Name, $value, "User")
    $value = $null
    Write-Host "  $($v.Name): set" -ForegroundColor Green
    $changed++
}

if ($changed -gt 0) {
    Write-Host ""
    Write-Host "Set $changed variable(s). Open a new terminal for them to take effect in child processes." -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "No changes made." -ForegroundColor DarkGray
}
