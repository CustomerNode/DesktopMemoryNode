<#
.SYNOPSIS
Applies the retention policy: always keep 4 distinct snapshots.

.DESCRIPTION
Custom retention -- restic's stock --keep-daily/weekly/monthly buckets *collapse* when
the same snapshot satisfies multiple buckets, which would silently leave you with fewer
than 4 snapshots. We instead pick four distinct snapshots by ID and forget the rest.

The four slots:
  1. NEWEST scheduled snapshot                        ("today")
  2. Newest scheduled at least 7 days OLDER than #1   ("1 week ago")
  3. Newest scheduled at least 30 days OLDER than #2  ("1 month ago")
  4. Newest manual (widget-triggered) snapshot        ("manual")

A young repo with no week-old or month-old snapshots keeps everything available
(can't pick a slot that doesn't exist). Once the history is long enough, the count
stabilizes at exactly 4.

After picking the keepers, all other snapshots are forgotten by ID and the repo is pruned.

.PARAMETER NoPrune
Skip the prune step (forget references but don't reclaim space).

.PARAMETER DryRun
Show what would be forgotten without doing it.

.EXAMPLE
.\Invoke-Forget.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoPrune,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath = Join-Path $here '..\lib\Memorybox.psm1'
Import-Module $libPath -Force

function Get-Snapshots {
    param([string[]]$Tags)
    $resticArgs = @('snapshots', '--json')
    foreach ($t in $Tags) { $resticArgs += @('--tag', $t) }
    $raw = Invoke-Restic @resticArgs 2>$null
    if (-not $raw) { return @() }
    $json = ($raw | Out-String).Trim()
    if (-not $json -or $json -eq 'null') { return @() }
    $parsed = $json | ConvertFrom-Json
    if (-not $parsed) { return @() }
    # PS 5.1: ConvertFrom-Json on an array passes through the pipeline as a
    # single item; normalize to a flat array of snapshot objects.
    $items = if ($parsed -is [array]) { $parsed } else { @($parsed) }
    $out = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($item in $items) {
        if (-not $item -or -not $item.time) { continue }
        $out.Add([PSCustomObject]@{
            Id   = $item.id
            Time = [datetime]$item.time
            Tags = $item.tags
        })
    }
    $out | Sort-Object Time -Descending
}

$lock = $null

try {
    Assert-MemoryboxReady
    Connect-MemoryboxSmb

    $lock = Lock-NodeOperation -Name 'forget'
    try { Invoke-Restic unlock --remove-all 2>$null | Out-Null } catch {}

    Write-DmnLog "Forget starting (target: 4 distinct slots -- today + ~7d + ~30d + manual; prune=$(-not $NoPrune))" -Kind 'forget'

    $scheduled = @(Get-Snapshots -Tags @('scheduled'))
    $manual    = @(Get-Snapshots -Tags @('manual'))

    $keepIds = New-Object System.Collections.Generic.HashSet[string]
    $picks = [ordered]@{ today = $null; week = $null; month = $null; manual = $null }

    # Slot 1: newest scheduled
    if ($scheduled.Count -gt 0) {
        $picks.today = $scheduled[0]
        [void]$keepIds.Add($scheduled[0].Id)
    }

    # Slot 2: first scheduled >= 7d older than slot 1
    if ($picks.today) {
        $cutoff = $picks.today.Time.AddDays(-7)
        $picks.week = $scheduled | Where-Object { $_.Time -le $cutoff } | Select-Object -First 1
        if ($picks.week) { [void]$keepIds.Add($picks.week.Id) }
    }

    # Slot 3: first scheduled >= 30d older than slot 2
    if ($picks.week) {
        $cutoff = $picks.week.Time.AddDays(-30)
        $picks.month = $scheduled | Where-Object { $_.Time -le $cutoff } | Select-Object -First 1
        if ($picks.month) { [void]$keepIds.Add($picks.month.Id) }
    }

    # Slot 4: newest manual
    if ($manual.Count -gt 0) {
        $picks.manual = $manual[0]
        [void]$keepIds.Add($manual[0].Id)
    }

    foreach ($slot in $picks.Keys) {
        $p = $picks[$slot]
        if ($p) {
            Write-DmnLog ("  keep [{0,-7}] {1}  {2:yyyy-MM-dd HH:mm}" -f $slot, $p.Id.Substring(0,8), $p.Time) -Kind 'forget'
        } else {
            Write-DmnLog ("  keep [{0,-7}] (no candidate)" -f $slot) -Kind 'forget'
        }
    }

    # Find everything to forget
    $all = @(Get-Snapshots)
    $toForget = @($all | Where-Object { -not $keepIds.Contains($_.Id) })

    if ($toForget.Count -eq 0) {
        Write-DmnLog "Nothing to forget (all $($all.Count) snapshots are keepers)." -Kind 'forget'
        return
    }

    Write-DmnLog "Forgetting $($toForget.Count) snapshot(s)..." -Kind 'forget'
    $forgetArgs = @('forget') + $toForget.Id
    if (-not $NoPrune) { $forgetArgs += '--prune' }
    if ($DryRun)        { $forgetArgs += '--dry-run' }

    Invoke-Restic @forgetArgs 2>&1 | Tee-Object -FilePath (Get-DmnLogPath -Kind 'forget') -Append
    if ($LASTEXITCODE -ne 0) { throw "restic forget failed (exit $LASTEXITCODE)." }

    Write-DmnLog "Forget OK ($($keepIds.Count) kept, $($toForget.Count) forgotten)" -Kind 'forget'
} catch {
    $err = $_.Exception.Message
    Write-DmnLog "Forget FAILED: $err" -Kind 'forget' -Level ERROR
    Send-MemoryboxToast -Title "Retention prune FAILED" -Body "Could not apply retention policy: $err  $(Get-DmnSupportLine)" -Level Error
    exit 1
} finally {
    if ($lock) { Unlock-NodeOperation -Handle $lock -Name 'forget' }
}
