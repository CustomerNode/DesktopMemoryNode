<#
.SYNOPSIS
Live UI smoke test that programmatically clicks "Test restore" in the dashboard,
types the password, clicks OK, and verifies the result dialog appears (instead
of the process crashing).

.DESCRIPTION
Uses UI Automation to drive the WinForms UI without a human. Catches the
"test restore crashes after entering password" regression that the headless
logic test (Test-TrayLogic.ps1) cannot catch because it skips the form path.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

$pwd = [Environment]::GetEnvironmentVariable('enc_pswd', 'User')
if (-not $pwd) { throw "enc_pswd not set" }

# Make sure no leftover tray windows are around
Get-Process powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -match 'Memory Box|Test|password' } |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

Remove-Item 'C:\Users\donca\AppData\Local\Temp\dmn-tray-debug.log' -ErrorAction SilentlyContinue

Write-Host "Launching dashboard via VBS shortcut path..."
Start-Process wscript.exe -ArgumentList "`"$env:LOCALAPPDATA\DesktopMemoryNode\launch-status.vbs`""

# Wait for dashboard window
Write-Host "Waiting for dashboard window..."
$root = [System.Windows.Automation.AutomationElement]::RootElement
$dashCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::NameProperty), "How your Memory Box is doing"
$dashboard = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $dashboard = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $dashCondition)
    if ($dashboard) { break }
}
if (-not $dashboard) { throw "Dashboard window did not appear within 10s" }
Write-Host "  Dashboard found"

# Find "Test restore" button
$btnCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::NameProperty), "Test restore"
$btn = $dashboard.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $btnCondition)
if (-not $btn) { throw "Test restore button not found" }
Write-Host "Clicking Test restore button..."
$invoke = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$invoke.Invoke()

# Wait for the "are you sure" confirmation dialog
$confirmCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::NameProperty), "Make sure I can get my files back"
$confirm = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $confirm = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $confirmCondition)
    if ($confirm) { break }
}
if (-not $confirm) { throw "Confirm dialog did not appear within 10s" }
Write-Host "  Confirm dialog found"

# Click "I have the password"
$okCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::NameProperty), "I have the password"
$okBtn = $confirm.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $okCondition)
if (-not $okBtn) { throw "Confirm OK button not found" }
$okBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

# Wait for the password dialog
$pwCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::NameProperty), "Memory Box -- type your password"
$pwDialog = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    $pwDialog = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $pwCondition)
    if ($pwDialog) { break }
}
if (-not $pwDialog) { throw "Password dialog did not appear within 10s" }
Write-Host "  Password dialog found"

# Find the text box and type the password
$tbCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), `
    ([System.Windows.Automation.ControlType]::Edit)
$tb = $pwDialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tbCondition)
if (-not $tb) { throw "Password textbox not found" }
$tbVP = $tb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$tbVP.SetValue($pwd)
Write-Host "  Password entered"

# Find OK button on the password dialog
$pwOkCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::NameProperty), "OK"
$pwOk = $pwDialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $pwOkCondition)
if (-not $pwOk) { throw "Password OK button not found" }
$pwOk.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Write-Host "  Password OK clicked"

# Wait up to 30s for the result dialog ("Test passed" or "Test didn't work")
$resultDialog = $null
$resultTitle  = $null
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    foreach ($name in 'Test passed','Test didn''t work','Couldn''t read backups','No snapshots yet','No file to test with') {
        $cond = New-Object System.Windows.Automation.PropertyCondition `
            ([System.Windows.Automation.AutomationElement]::NameProperty), "Memory Box"
        # The result dialog has title 'Memory Box', but we identify it by hero text
        $candidates = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($c in $candidates) {
            $heroCond = New-Object System.Windows.Automation.PropertyCondition `
                ([System.Windows.Automation.AutomationElement]::NameProperty), $name
            $hero = $c.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $heroCond)
            if ($hero) { $resultDialog = $c; $resultTitle = $name; break }
        }
        if ($resultDialog) { break }
    }
    if ($resultDialog) { break }
}

if (-not $resultDialog) {
    Write-Host "Result dialog did NOT appear within 30s -- this is the crash" -ForegroundColor Red
    Write-Host ""
    Write-Host "=== Debug log ==="
    Get-Content 'C:\Users\donca\AppData\Local\Temp\dmn-tray-debug.log' -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "=== Tray PowerShell processes still alive ==="
    Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 80MB } | Format-Table Id, MainWindowTitle, @{N='MB';E={[Math]::Round($_.WorkingSet64/1MB,1)}}
    exit 1
}

Write-Host ""
Write-Host "Result dialog appeared with title: $resultTitle" -ForegroundColor Green

# Click OK to dismiss result
$resOkCondition = New-Object System.Windows.Automation.PropertyCondition `
    ([System.Windows.Automation.AutomationElement]::NameProperty), "OK"
$resOk = $resultDialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $resOkCondition)
if ($resOk) { $resOk.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }

if ($resultTitle -ne 'Test passed') {
    Write-Host "FAIL: result title was '$resultTitle' but expected 'Test passed'" -ForegroundColor Red
    Write-Host ""
    Write-Host "=== Debug log ==="
    Get-Content 'C:\Users\donca\AppData\Local\Temp\dmn-tray-debug.log' -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "PASS: end-to-end click flow works." -ForegroundColor Green
exit 0
