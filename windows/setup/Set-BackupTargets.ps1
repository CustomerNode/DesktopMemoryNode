<#
.SYNOPSIS
Configures which paths get backed up. Writes targets.json under %LOCALAPPDATA%\DesktopMemoryNode\.

.DESCRIPTION
Three modes:
  - Default: opens an interactive editor where you can accept the defaults, add paths, or remove them.
  - -Show: prints the current configuration and exits.
  - -Reset: replaces targets.json with the default config (user data folders, common excludes).
  - -Include / -Exclude with explicit paths: scriptable, non-interactive.

The default config covers Documents, Desktop, Pictures, Videos, Music, Downloads, and excludes
typical caches, OS metadata, and the AppData tree (which is mostly reinstall-able app state).

.EXAMPLE
.\Set-BackupTargets.ps1
Interactive editor.

.EXAMPLE
.\Set-BackupTargets.ps1 -Show
Print current config.

.EXAMPLE
.\Set-BackupTargets.ps1 -Reset
Restore defaults.

.EXAMPLE
.\Set-BackupTargets.ps1 -Include 'C:\Projects','C:\Users\me\Documents' -Exclude '**/node_modules'
Set explicitly (no prompts).
#>
[CmdletBinding(DefaultParameterSetName='Interactive')]
param(
    [Parameter(ParameterSetName='Show')]    [switch]$Show,
    [Parameter(ParameterSetName='Reset')]   [switch]$Reset,
    [Parameter(ParameterSetName='Explicit', Mandatory)] [string[]]$Include,
    [Parameter(ParameterSetName='Explicit')]            [string[]]$Exclude = @()
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path (Split-Path -Parent $here) 'lib\Memorybox.psm1'
Import-Module $libPath -Force

function Show-Targets($t) {
    Write-Host ""
    Write-Host "Include ($(@($t.include).Count)):" -ForegroundColor Cyan
    foreach ($p in $t.include) {
        $exists = Test-Path $p
        $color  = if ($exists) { 'Gray' } else { 'Yellow' }
        $tag    = if ($exists) { '' } else { '  (not found)' }
        Write-Host "  $p$tag" -ForegroundColor $color
    }
    Write-Host "Exclude ($(@($t.exclude).Count)):" -ForegroundColor Cyan
    foreach ($p in $t.exclude) { Write-Host "  $p" -ForegroundColor Gray }
    Write-Host ""
}

if ($Show) {
    $current = Get-BackupTargets
    Show-Targets $current
    return
}

if ($Reset) {
    $defaults = Get-DefaultBackupTargets
    Set-BackupTargets -Include $defaults.include -Exclude $defaults.exclude
    Write-Host "Reset to defaults." -ForegroundColor Green
    Show-Targets $defaults
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Explicit') {
    Set-BackupTargets -Include $Include -Exclude $Exclude
    Write-Host "Saved." -ForegroundColor Green
    Show-Targets (Get-BackupTargets)
    return
}

# --- Interactive ---
$targetsPath = Get-DmnTargetsPath
$exists = Test-Path $targetsPath
$current = Get-BackupTargets
if (-not $exists) {
    Write-Host "No targets.json yet -- starting from defaults." -ForegroundColor DarkGray
}
Show-Targets $current

while ($true) {
    Write-Host "Actions: [a]dd include  [r]emove include  [x] add exclude  [X] remove exclude  [s]ave  [q]uit without saving" -ForegroundColor Cyan
    $action = Read-Host "Action"
    switch ($action) {
        'a' {
            $p = Read-Host "Path to add to INCLUDE"
            if ($p) { $current.include = @($current.include) + $p; Show-Targets $current }
        }
        'r' {
            $p = Read-Host "Path to remove from INCLUDE (exact match)"
            $current.include = @($current.include | Where-Object { $_ -ne $p })
            Show-Targets $current
        }
        'x' {
            $p = Read-Host "Pattern to add to EXCLUDE"
            if ($p) { $current.exclude = @($current.exclude) + $p; Show-Targets $current }
        }
        'X' {
            $p = Read-Host "Pattern to remove from EXCLUDE (exact match)"
            $current.exclude = @($current.exclude | Where-Object { $_ -ne $p })
            Show-Targets $current
        }
        's' {
            if ($current.include.Count -eq 0) {
                Write-Host "Refusing to save: include list is empty." -ForegroundColor Red
                continue
            }
            Set-BackupTargets -Include $current.include -Exclude $current.exclude
            Write-Host "Saved to $targetsPath" -ForegroundColor Green
            return
        }
        'q' {
            Write-Host "Discarded." -ForegroundColor DarkGray
            return
        }
        default { Write-Host "Unknown action." -ForegroundColor Yellow }
    }
}
