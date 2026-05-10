<#
.SYNOPSIS
Registers the DesktopMemoryNode scheduled tasks in Windows Task Scheduler.

.DESCRIPTION
Creates three tasks under \DesktopMemoryNode\:
  - Backup        -- daily at 02:00, runs windows\agent\Invoke-Backup.ps1
  - Forget        -- weekly Sunday at 03:00, runs windows\agent\Invoke-Forget.ps1
  - Verify        -- weekly Sunday at 04:00, runs windows\agent\Invoke-Verify.ps1 (Phase 2)
  - TestRestore   -- monthly first-of-month at 05:00, runs windows\agent\Invoke-TestRestore.ps1 (Phase 2)

All tasks run in the current user's context (no SYSTEM, no admin), wake the computer if asleep,
retry on failure (3 retries, 10 min apart), and start within a random 0-15 min window to spread load.

Idempotent: re-registers tasks if they already exist.

.PARAMETER RepoRoot
Path to the DesktopMemoryNode repo. Defaults to the repo this script is part of.

.PARAMETER Remove
Unregister the tasks instead of installing.

.EXAMPLE
.\Install-Schedule.ps1
Install/refresh the scheduled tasks.

.EXAMPLE
.\Install-Schedule.ps1 -Remove
Remove the scheduled tasks.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..')).Path,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$folder    = '\DesktopMemoryNode\'
$psExe     = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

function New-TaskDefinition {
    param(
        [string]$Name,
        [string]$ScriptRelative,
        [Microsoft.Management.Infrastructure.CimInstance[]]$Triggers,
        [string[]]$ScriptArgs = @()
    )

    $scriptFull = Join-Path $RepoRoot $ScriptRelative
    if (-not (Test-Path $scriptFull)) {
        Write-Warning "Script not found, skipping task '$Name': $scriptFull"
        return $null
    }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptFull`"") + $ScriptArgs
    $action  = New-ScheduledTaskAction -Execute $psExe -Argument ($argList -join ' ')

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -WakeToRun `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 10)

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask `
        -TaskName  $Name `
        -TaskPath  $folder `
        -Action    $action `
        -Trigger   $Triggers `
        -Settings  $settings `
        -Principal $principal `
        -Force | Out-Null
}

if ($Remove) {
    Get-ScheduledTask -TaskPath $folder -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Removing $($_.TaskPath)$($_.TaskName)" -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -Confirm:$false
    }
    Write-Host "Done." -ForegroundColor Green
    return
}

Write-Host "Registering DesktopMemoryNode scheduled tasks under $folder ..." -ForegroundColor Cyan

# Daily backup at 02:00
New-TaskDefinition -Name 'Backup' `
    -ScriptRelative 'windows\agent\Invoke-Backup.ps1' `
    -ScriptArgs @('-QuietOnSuccess') `
    -Triggers (New-ScheduledTaskTrigger -Daily -At '02:00')

# Weekly forget+prune Sunday 03:00
New-TaskDefinition -Name 'Forget' `
    -ScriptRelative 'windows\agent\Invoke-Forget.ps1' `
    -Triggers (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '03:00')

# Weekly verify Sunday 04:00 (script may not exist until Phase 2 -- task will be skipped if so)
New-TaskDefinition -Name 'Verify' `
    -ScriptRelative 'windows\agent\Invoke-Verify.ps1' `
    -Triggers (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00')

# Monthly test-restore (~ every 30 days at 05:00). Phase 2.
$monthlyTrigger = New-ScheduledTaskTrigger -Daily -DaysInterval 30 -At '05:00'
New-TaskDefinition -Name 'TestRestore' `
    -ScriptRelative 'windows\agent\Invoke-TestRestore.ps1' `
    -Triggers $monthlyTrigger

Write-Host ""
Write-Host "Installed tasks:" -ForegroundColor Green
Get-ScheduledTask -TaskPath $folder | Format-Table TaskName, State, @{Name='NextRunTime'; Expression={(Get-ScheduledTaskInfo -TaskPath $folder -TaskName $_.TaskName).NextRunTime}}
