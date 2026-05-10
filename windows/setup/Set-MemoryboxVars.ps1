<#
.SYNOPSIS
Sets the MEMORYBOX_* user environment variables that point at the cloud memorybox.

.DESCRIPTION
By default, only prompts for variables that aren't already set. Use -Force to re-prompt
for everything. Use -Show to display current state without changing anything.

The password is read via a hidden prompt (Read-Host -AsSecureString) and never echoed.
All variables are stored at User scope (no admin required).

.EXAMPLE
.\Set-MemoryboxVars.ps1
Prompts only for missing values.

.EXAMPLE
.\Set-MemoryboxVars.ps1 -Force
Re-prompts for every value, overwriting whatever's already set.

.EXAMPLE
.\Set-MemoryboxVars.ps1 -Show
Prints current state (password shown only as <set>/<not set>).
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Show
)

$vars = @(
    @{ Name = 'MEMORYBOX_HOST';     Prompt = 'MEMORYBOX_HOST (IP or hostname)'; Secret = $false },
    @{ Name = 'MEMORYBOX_PORT';     Prompt = 'MEMORYBOX_PORT';                  Secret = $false },
    @{ Name = 'MEMORYBOX_USER';     Prompt = 'MEMORYBOX_USER';                  Secret = $false },
    @{ Name = 'MEMORYBOX_PASSWORD'; Prompt = 'MEMORYBOX_PASSWORD';              Secret = $true  }
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

$changed = 0
foreach ($v in $vars) {
    $existing = [Environment]::GetEnvironmentVariable($v.Name, "User")
    $needPrompt = $Force -or [string]::IsNullOrEmpty($existing)
    if (-not $needPrompt) {
        Write-Host "  $($v.Name): already set, skipping (use -Force to overwrite)" -ForegroundColor DarkGray
        continue
    }

    if ($v.Secret) {
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
