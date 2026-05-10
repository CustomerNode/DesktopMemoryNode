<#
.SYNOPSIS
End-to-end logic tests for the tray app -- runs the same code paths without showing forms.

.DESCRIPTION
The tray app's click handlers each call a function that does the actual work
(Start-TestRestore, snapshot tree population, etc.). This script extracts those
functions and exercises them against the live NAS so we can validate behavior
without a human clicking buttons.

Pre-requisites: All MEMORYBOX_* + enc_pswd env vars set, NAS reachable, restic
installed, repo initialized, at least one snapshot.

Exit code 0 if all checks pass.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $PSCommandPath
$libPath = Join-Path (Split-Path -Parent $here) 'lib\Memorybox.psm1'
Import-Module $libPath -Force

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$failures = 0
function Check {
    param([string]$Label, [scriptblock]$Test)
    try {
        & $Test
        Write-Host "[OK]   $Label" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $Label : $($_.Exception.Message)" -ForegroundColor Red
        $script:failures++
    }
}

Write-Host ""
Write-Host "Tray logic tests" -ForegroundColor Cyan
Write-Host "================" -ForegroundColor Cyan

# 1. Custom icon loads from disk
Check "Memory-Box.ico exists at expected path" {
    $iconPath = Join-Path $env:LOCALAPPDATA 'DesktopMemoryNode\Memory-Box.ico'
    if (-not (Test-Path $iconPath)) { throw "$iconPath not found -- run Install-Tray.ps1" }
    if ((Get-Item $iconPath).Length -lt 5000) { throw "Icon file is suspiciously small ($((Get-Item $iconPath).Length) bytes); should be multi-size, ~10KB+" }
}

Check "Icon loads as System.Drawing.Icon" {
    $iconPath = Join-Path $env:LOCALAPPDATA 'DesktopMemoryNode\Memory-Box.ico'
    $icon = New-Object System.Drawing.Icon $iconPath
    if (-not $icon) { throw "Icon loaded as null" }
    $icon.Dispose()
}

# 2. Display config reads cleanly
Check "Get-DmnDisplayConfig returns the three fields" {
    $d = Get-DmnDisplayConfig
    foreach ($p in 'UserName','TechName','TechContact') {
        if ($d.PSObject.Properties.Name -notcontains $p) { throw "missing property $p" }
    }
}

Check "Get-DmnSupportLine returns a non-empty string" {
    $line = Get-DmnSupportLine
    if ([string]::IsNullOrWhiteSpace($line)) { throw "empty support line" }
}

# 3. Connection probe
Check "Test-MemoryboxConnection returns reachable status" {
    $r = Test-MemoryboxConnection
    if (-not $r.IcmpReachable) { throw "ICMP unreachable" }
    if (-not $r.TcpReachable)  { throw "TCP unreachable" }
}

# 4. Restic + snapshots
Check "restic snapshots --json returns at least one snapshot" {
    $raw = Invoke-Restic snapshots --json 2>$null
    if (-not $raw) { throw "no output from restic snapshots" }
    $snaps = @(($raw | Out-String).Trim() | ConvertFrom-Json)
    if ($snaps.Count -lt 1) { throw "no snapshots in repo" }
}

# 5. Snapshot tree-population logic (simulates Show-SnapshotsForm's right-pane build)
Check "Snapshot tree-population processes restic ls output without error" {
    $rawSnaps = Invoke-Restic snapshots --json 2>$null
    $sid = (@(($rawSnaps | Out-String).Trim() | ConvertFrom-Json) | Sort-Object @{Expression={[datetime]$_.time}} -Descending | Select-Object -First 1).id

    $raw = Invoke-Restic ls --json $sid 2>$null
    if (-not $raw) { throw "no output from restic ls" }

    # Build TreeNode hierarchy in memory (no form needed)
    $root = New-Object System.Windows.Forms.TreeNode "ROOT"
    $count = 0
    foreach ($line in ($raw -split "`n")) {
        $line = $line.Trim(); if (-not $line) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if (-not $obj -or $obj.struct_type -ne 'node') { continue }
        $parts = @(($obj.path -split '/') | Where-Object { $_ })
        if ($parts.Count -eq 0) { continue }

        $cursor = $root
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $part = [string]$parts[$i]
            $existing = $null
            for ($j = 0; $j -lt $cursor.Nodes.Count; $j++) {
                $child = $cursor.Nodes.Item($j)
                $ct = [string]$child.Text
                if ($ct -eq $part -or $ct.StartsWith($part + '  ')) { $existing = $child; break }
            }
            if ($existing) { $cursor = $existing }
            else { $cursor = $cursor.Nodes.Add([string]$part) }
        }
        $count++
    }
    if ($count -eq 0) { throw "no nodes parsed from ls output" }
    if ($root.Nodes.Count -eq 0) { throw "no children added to root" }
}

# 6. Test-restore inline logic (the body of Start-TestRestore)
Check "Test-restore inline flow round-trips a small file" {
    $pwd = [Environment]::GetEnvironmentVariable('enc_pswd','User')
    if (-not $pwd) { throw "enc_pswd not set -- can't run round-trip test" }
    Set-ResticPasswordOverride -Password $pwd
    $scratch = Join-Path $env:TEMP "dmn-trayfn-test-$([guid]::NewGuid().Guid.Substring(0,8))"
    try {
        Connect-MemoryboxSmb
        $rawSnaps = Invoke-Restic snapshots --json 2>$null
        $newest = (@(($rawSnaps | Out-String).Trim() | ConvertFrom-Json) | Sort-Object @{Expression={[datetime]$_.time}} -Descending | Select-Object -First 1)
        $rawLs = Invoke-Restic ls --json $newest.id 2>$null
        $files = @()
        foreach ($line in ($rawLs -split "`n")) {
            $line = $line.Trim(); if (-not $line) { continue }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.struct_type -eq 'node' -and $obj.type -eq 'file' -and $obj.size -gt 0 -and $obj.size -le 1MB) {
                $files += $obj
            }
        }
        if ($files.Count -eq 0) { throw "no test file found" }
        $testFile = $files | Get-Random
        New-Item -ItemType Directory -Path $scratch -Force | Out-Null
        # Restic on Windows emits a benign NativeCommandError when restoring under
        # %TEMP% (can't set timestamps on the synthetic parent dirs). Swallow it --
        # we verify success by file existence + size below.
        try { Invoke-Restic restore $newest.id --target $scratch --include $testFile.path 2>$null | Out-Null } catch {}
        $restored = Get-ChildItem $scratch -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -eq $testFile.size } | Select-Object -First 1
        if (-not $restored) { throw "no restored file matched expected size" }
    } finally {
        Clear-ResticPasswordOverride
        if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
    }
}

# 7. Tray script syntax (catches anything that broke since last commit)
Check "BackupTray.ps1 parses cleanly" {
    $trayScript = Join-Path (Split-Path -Parent $here) 'tray\BackupTray.ps1'
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($trayScript, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw "$($errors.Count) parse error(s); first: $($errors[0].Message)" }
}

Check "Install-Tray.ps1 parses cleanly" {
    $script = Join-Path (Split-Path -Parent $here) 'tray\Install-Tray.ps1'
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw "$($errors.Count) parse error(s); first: $($errors[0].Message)" }
}

# 8. Live UI smoke test -- launch via the VBS launcher exactly as the desktop
# shortcut would, and verify a Memory Box window appears (not "PowerShell").
Check "VBS launcher (-ShowStatus) opens a Memory Box window, not a PowerShell one" {
    $vbs = Join-Path $env:LOCALAPPDATA 'DesktopMemoryNode\launch-status.vbs'
    if (-not (Test-Path $vbs)) { throw "$vbs not found -- run Install-Tray.ps1" }

    $before = @(Get-Process powershell -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Start-Process wscript.exe -ArgumentList "`"$vbs`""
    $found = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $candidates = Get-Process powershell -ErrorAction SilentlyContinue |
                       Where-Object { $_.Id -notin $before -and $_.MainWindowTitle }
        if ($candidates) { $found = $candidates | Select-Object -First 1; break }
    }
    if (-not $found) { throw "no powershell window appeared within 10s" }
    $title = $found.MainWindowTitle
    # Cleanup -- close the window
    Stop-Process -Id $found.Id -Force -ErrorAction SilentlyContinue

    if ($title -notmatch 'Memory Box|How your Memory Box') {
        throw "window title was '$title', expected to mention Memory Box"
    }
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All tray logic tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
