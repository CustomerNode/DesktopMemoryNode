<#
.SYNOPSIS
Memory Box -- system tray app for the DesktopMemoryNode backup system.

.DESCRIPTION
A polished tray app designed for non-technical users. Lives next to the system clock.
Left-click for status, right-click for menu. Features hidden behind the "Advanced"
submenu for the person who set it up; everything else is plain language.

Personalization (optional, set as User env vars -- see shared/CONFIG.md):
  DMN_DISPLAY_NAME  - Greeted name (e.g. "Mom"). Empty = generic.
  DMN_TECH_NAME     - Tech support person (e.g. "Sam"). Empty = "tech support".
  DMN_TECH_CONTACT  - Tech support phone or email. Empty = name only.

Use windows/tray/Install-Tray.ps1 to launch at login.
#>
[CmdletBinding()]
param(
    # When set, just opens the Status form and exits; does not start the tray.
    # Used by the desktop and Start Menu "Memory Box" shortcuts.
    [switch]$ShowStatus,
    # Same idea but opens the snapshots browser.
    [switch]$ShowSnapshots
)

$ErrorActionPreference = 'Continue'

# Debug log -- always written so we can diagnose silent failures.
$script:DebugLog = Join-Path $env:TEMP 'dmn-tray-debug.log'
function Write-DebugLine { param([string]$M) Add-Content -Path $script:DebugLog -Value ("{0:yyyy-MM-ddTHH:mm:ss.fff} [PID $PID] {1}" -f (Get-Date), $M) }
Write-DebugLine "BackupTray.ps1 starting (ShowStatus=$($PSBoundParameters.ContainsKey('ShowStatus')) ShowSnapshots=$($PSBoundParameters.ContainsKey('ShowSnapshots')))"

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing       -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Write-DebugLine "WinForms loaded"
} catch {
    Write-DebugLine "FAILED to load WinForms: $($_.Exception.Message)"
    throw
}

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$libPath  = Join-Path $here '..\lib\Memorybox.psm1'
$repoRoot = (Resolve-Path (Join-Path $here '..\..')).Path
Import-Module $libPath -Force

# =====================================================================================
# Visual system -- colors, fonts, helpers
# =====================================================================================

$Theme = @{
    Bg          = [System.Drawing.Color]::FromArgb(250, 250, 250)
    Card        = [System.Drawing.Color]::White
    Primary     = [System.Drawing.Color]::FromArgb(61, 122, 174)
    PrimaryDark = [System.Drawing.Color]::FromArgb(45,  98, 144)
    Success     = [System.Drawing.Color]::FromArgb(45, 142,  80)
    Warning     = [System.Drawing.Color]::FromArgb(201, 116, 12)
    Danger      = [System.Drawing.Color]::FromArgb(184, 60, 60)
    Heart       = [System.Drawing.Color]::FromArgb(192, 74, 107)
    Text        = [System.Drawing.Color]::FromArgb(26, 26, 26)
    TextMuted   = [System.Drawing.Color]::FromArgb(107, 107, 107)
    Divider     = [System.Drawing.Color]::FromArgb(229, 229, 229)
}

# --------------------------------------------------------------------------------------
# Custom tray icon -- a rounded blue square with "MB" in white. Drawn at 32x32 because
# Windows scales tray icons from this size. Returns a System.Drawing.Icon.
# --------------------------------------------------------------------------------------

function New-MemoryBoxIcon {
    # Single source of truth for the tray icon: the multi-size .ico file generated
    # by Install-Tray.ps1 (rounded blue square with a centered white heart).
    # If the .ico isn't present yet, fall back to a built-in icon so the tray still
    # has a visual.
    $iconPath = Join-Path $env:LOCALAPPDATA 'DesktopMemoryNode\Memory-Box.ico'
    if (Test-Path $iconPath) {
        try { return New-Object System.Drawing.Icon $iconPath }
        catch { }
    }
    return [System.Drawing.SystemIcons]::Shield
}

$Font = @{
    Hero      = New-Object System.Drawing.Font('Segoe UI Light',     22, [System.Drawing.FontStyle]::Regular)
    Heading   = New-Object System.Drawing.Font('Segoe UI Semibold',  13, [System.Drawing.FontStyle]::Regular)
    Body      = New-Object System.Drawing.Font('Segoe UI',           11, [System.Drawing.FontStyle]::Regular)
    BodyBold  = New-Object System.Drawing.Font('Segoe UI Semibold',  11, [System.Drawing.FontStyle]::Regular)
    Small     = New-Object System.Drawing.Font('Segoe UI',            9, [System.Drawing.FontStyle]::Regular)
    Mono      = New-Object System.Drawing.Font('Consolas',           10, [System.Drawing.FontStyle]::Regular)
}

# --------------------------------------------------------------------------------------
# Friendly date formatting
# --------------------------------------------------------------------------------------

function Format-FriendlyDateTime {
    param([datetime]$When, [datetime]$Now = (Get-Date))
    if (-not $When) { return '(never)' }
    $diff = $Now - $When
    $todayStart = $Now.Date
    $whenDate   = $When.Date
    $timeStr    = $When.ToString('h:mm tt')

    if ($whenDate -eq $todayStart) {
        if ($diff.TotalMinutes -lt 1)   { return 'just now' }
        if ($diff.TotalMinutes -lt 60)  { return ("about {0} minute{1} ago" -f [int]$diff.TotalMinutes, $(if ([int]$diff.TotalMinutes -eq 1) {''} else {'s'})) }
        if ($diff.TotalHours -lt 6)     { return ("about {0} hour{1} ago" -f [int]$diff.TotalHours, $(if ([int]$diff.TotalHours -eq 1) {''} else {'s'})) }
        return "today at $timeStr"
    }
    if ($whenDate -eq $todayStart.AddDays(-1)) { return "yesterday at $timeStr" }
    if ($diff.TotalDays -lt 7) { return ("$($When.ToString('dddd')) at $timeStr") }
    return $When.ToString('MMM d') + " at $timeStr"
}

function Format-FriendlyFutureDateTime {
    param([datetime]$When, [datetime]$Now = (Get-Date))
    if (-not $When -or $When -le [datetime]::MinValue) { return '(unscheduled)' }
    $todayStart = $Now.Date
    $whenDate   = $When.Date
    $timeStr    = $When.ToString('h:mm tt')
    if ($whenDate -eq $todayStart)            { return "today at $timeStr" }
    if ($whenDate -eq $todayStart.AddDays(1)) { return "tomorrow at $timeStr" }
    if (($When - $Now).TotalDays -lt 7)       { return ("$($When.ToString('dddd')) at $timeStr") }
    return $When.ToString('MMM d') + " at $timeStr"
}

# --------------------------------------------------------------------------------------
# Status indicator (colored circle + label) -- custom-painted Panel
# --------------------------------------------------------------------------------------

function New-StatusPill {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][ValidateSet('Good','Warn','Bad','Idle')][string]$State,
        [string]$Detail = ''
    )

    $color = switch ($State) {
        'Good' { $Theme.Success }
        'Warn' { $Theme.Warning }
        'Bad'  { $Theme.Danger }
        'Idle' { $Theme.TextMuted }
    }

    $row = New-Object System.Windows.Forms.Panel
    $row.Height = 38
    $row.Dock   = 'Top'
    $row.BackColor = $Theme.Card
    $row.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)

    $row.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $brush = New-Object System.Drawing.SolidBrush $color
        $g.FillEllipse($brush, 4, 12, 14, 14)
        $brush.Dispose()
    }.GetNewClosure())

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $Label
    $lbl.AutoSize = $true
    $lbl.Font     = $Font.BodyBold
    $lbl.ForeColor = $Theme.Text
    $lbl.Location = New-Object System.Drawing.Point(28, 9)
    $row.Controls.Add($lbl)

    if ($Detail) {
        $det = New-Object System.Windows.Forms.Label
        $det.Text     = $Detail
        $det.AutoSize = $true
        $det.Font     = $Font.Body
        $det.ForeColor = $Theme.TextMuted
        $det.Location = New-Object System.Drawing.Point(28, 9)
        # Position to right of label (computed after handle creation)
        $row.Add_HandleCreated({
            $det.Location = New-Object System.Drawing.Point(($lbl.Right + 6), 9)
        }.GetNewClosure())
        $row.Controls.Add($det)
    }

    $row
}

# --------------------------------------------------------------------------------------
# Primary button factory
# --------------------------------------------------------------------------------------

function New-PrimaryButton {
    param([string]$Text, [int]$Width = 140, [int]$Height = 38)

    $b = New-Object System.Windows.Forms.Button
    $b.Text       = $Text
    $b.Width      = $Width
    $b.Height     = $Height
    $b.FlatStyle  = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor  = $Theme.Primary
    $b.ForeColor  = [System.Drawing.Color]::White
    $b.Font       = $Font.BodyBold
    $b.Cursor     = [System.Windows.Forms.Cursors]::Hand
    $b.add_MouseEnter({ $this.BackColor = $Theme.PrimaryDark }.GetNewClosure())
    $b.add_MouseLeave({ $this.BackColor = $Theme.Primary }.GetNewClosure())
    $b
}

function New-SecondaryButton {
    param([string]$Text, [int]$Width = 100, [int]$Height = 38)

    $b = New-Object System.Windows.Forms.Button
    $b.Text       = $Text
    $b.Width      = $Width
    $b.Height     = $Height
    $b.FlatStyle  = 'Flat'
    $b.FlatAppearance.BorderSize  = 1
    $b.FlatAppearance.BorderColor = $Theme.Divider
    $b.BackColor  = $Theme.Card
    $b.ForeColor  = $Theme.Text
    $b.Font       = $Font.Body
    $b.Cursor     = [System.Windows.Forms.Cursors]::Hand
    $b
}

# --------------------------------------------------------------------------------------
# Footer: "Made with care by Sam -- sam@..."
# --------------------------------------------------------------------------------------

function Add-Footer {
    param([System.Windows.Forms.Form]$Form, [int]$Y)

    $disp = Get-DmnDisplayConfig
    $name = if ($disp.TechName) { $disp.TechName } else { 'your tech support person' }

    # Heart panel (custom-paint a small heart shape)
    $heart = New-Object System.Windows.Forms.Panel
    $heart.Size     = New-Object System.Drawing.Size(20, 18)
    $heart.Location = New-Object System.Drawing.Point(15, $Y)
    $heart.BackColor = $Form.BackColor
    $heart.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $brush = New-Object System.Drawing.SolidBrush $Theme.Heart
        # Two circles for the lobes, triangle for the point -- crude but warm
        $g.FillEllipse($brush, 2, 3, 9, 9)
        $g.FillEllipse($brush, 9, 3, 9, 9)
        $pts = @(
            (New-Object System.Drawing.PointF 2.5,  9),
            (New-Object System.Drawing.PointF 17.5, 9),
            (New-Object System.Drawing.PointF 10,  17)
        )
        $g.FillPolygon($brush, $pts)
        $brush.Dispose()
    }.GetNewClosure())
    $Form.Controls.Add($heart)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize  = $true
    $lbl.Font      = $Font.Small
    $lbl.ForeColor = $Theme.TextMuted
    if ($disp.TechContact) {
        $lbl.Text = "Made with care by $name." + "    Need help? Email $($disp.TechContact)"
    } else {
        $lbl.Text = "Made with care by $name."
    }
    $lbl.Location = New-Object System.Drawing.Point(40, ($Y + 2))
    $Form.Controls.Add($lbl)
}

# --------------------------------------------------------------------------------------
# Form factory -- consistent base for all dialogs
# --------------------------------------------------------------------------------------

function New-MemoryForm {
    param([string]$Title, [int]$Width = 640, [int]$Height = 520, [switch]$FixedSize)

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = $Title
    $form.Size          = New-Object System.Drawing.Size($Width, $Height)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor     = $Theme.Bg
    $form.Font          = $Font.Body
    $form.Icon          = New-MemoryBoxIcon
    $form.ShowInTaskbar = $true
    $form.WindowState   = 'Normal'
    if ($FixedSize) {
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
    }

    $form.Add_Shown({
        $form.TopMost = $true
        $form.Activate()
        $form.BringToFront()
        $form.Focus() | Out-Null
        $form.TopMost = $false
    }.GetNewClosure())

    $form
}

# =====================================================================================
# WELCOME (first-launch) dialog
# =====================================================================================

function Show-WelcomeForm {
    $disp = Get-DmnDisplayConfig
    $userName = if ($disp.UserName) { $disp.UserName } else { 'there' }
    $techName = if ($disp.TechName) { $disp.TechName } else { 'your tech support person' }

    $form = New-MemoryForm -Title "Welcome to your Memory Box" -Width 560 -Height 480 -FixedSize

    $hero = New-Object System.Windows.Forms.Label
    $hero.Text      = "Hi $userName!"
    $hero.Font      = $Font.Hero
    $hero.ForeColor = $Theme.Primary
    $hero.AutoSize  = $true
    $hero.Location  = New-Object System.Drawing.Point(30, 30)
    $form.Controls.Add($hero)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text      = "This is your Memory Box."
    $sub.Font      = $Font.Heading
    $sub.ForeColor = $Theme.Text
    $sub.AutoSize  = $true
    $sub.Location  = New-Object System.Drawing.Point(30, 80)
    $form.Controls.Add($sub)

    $body = New-Object System.Windows.Forms.Label
    $body.Text = @"
It quietly saves copies of your important files
(Documents, Photos, Videos, Music, and Downloads)
to a backup box every day at 2:00 AM, so they're
always safe.

Look for the small shield icon next to the clock.

  - Click it any time to see how things are going.
  - Right-click for more options.

If something ever needs attention, you'll see a
notification -- and $techName will too.
"@
    $body.Font      = $Font.Body
    $body.ForeColor = $Theme.Text
    $body.AutoSize  = $true
    $body.Location  = New-Object System.Drawing.Point(30, 120)
    $form.Controls.Add($body)

    $okBtn = New-PrimaryButton -Text "Got it -- thank you!" -Width 200
    $okBtn.Location = New-Object System.Drawing.Point(180, 360)
    $okBtn.Add_Click({ $form.Close() }.GetNewClosure())
    $form.AcceptButton = $okBtn
    $form.Controls.Add($okBtn)

    Add-Footer -Form $form -Y 410

    $form.ShowDialog() | Out-Null
}

# =====================================================================================
# STATUS form -- the hero
# =====================================================================================

function Show-StatusForm {
    $cfg   = Get-MemoryboxConfig
    $state = Get-NodeState
    $disp  = Get-DmnDisplayConfig

    $form = New-MemoryForm -Title "How your Memory Box is doing" -Width 700 -Height 670

    # Hero greeting
    $userName = if ($disp.UserName) { $disp.UserName } else { '' }
    $greetingText = if ($userName) { "Hi $userName" } else { "Your Memory Box" }
    $greeting = New-Object System.Windows.Forms.Label
    $greeting.Text      = $greetingText
    $greeting.Font      = $Font.Hero
    $greeting.ForeColor = $Theme.Primary
    $greeting.AutoSize  = $true
    $greeting.Location  = New-Object System.Drawing.Point(25, 22)
    $form.Controls.Add($greeting)

    # Headline status (overall verdict)
    $missing = Get-MissingMemoryboxVars
    $allGood = ($missing.Count -eq 0) -and ($state.LastBackupOk -ne $false) -and ($state.LastVerifyOk -ne $false)

    $headline = New-Object System.Windows.Forms.Label
    if ($missing.Count -gt 0) {
        $headline.Text      = "Setup isn't quite finished."
        $headline.ForeColor = $Theme.Warning
    } elseif (-not $state.LastBackupAt) {
        $headline.Text      = "First backup hasn't run yet."
        $headline.ForeColor = $Theme.TextMuted
    } elseif ($state.LastBackupOk -eq $false) {
        $headline.Text      = "Last backup didn't complete."
        $headline.ForeColor = $Theme.Danger
    } else {
        $headline.Text      = "Your files are safe."
        $headline.ForeColor = $Theme.Success
    }
    $headline.Font      = $Font.Heading
    $headline.AutoSize  = $true
    $headline.Location  = New-Object System.Drawing.Point(25, 70)
    $form.Controls.Add($headline)

    # Card panel for status pills
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(25, 110)
    $card.Size     = New-Object System.Drawing.Size(610, 180)
    $card.BackColor = $Theme.Card
    $card.Padding   = New-Object System.Windows.Forms.Padding(20, 14, 20, 14)
    $card.BorderStyle = 'FixedSingle'
    $form.Controls.Add($card)

    # We add pills bottom-up because Dock=Top stacks in reverse (most recent at top)
    function Add-PillTo($card, $label, $state, $detail) {
        $p = New-StatusPill -Label $label -State $state -Detail $detail
        $card.Controls.Add($p)
        $p.BringToFront()
    }

    # Setup completeness
    if ($missing.Count -gt 0) {
        Add-PillTo $card "Setup is incomplete" 'Bad' "Missing: $($missing -join ', ')"
    } else {
        Add-PillTo $card "Setup is complete" 'Good' ""
    }

    # Backup
    if (-not $state.LastBackupAt) {
        Add-PillTo $card "Files saved" 'Idle' "no backups yet"
    } elseif ($state.LastBackupOk -eq $false) {
        Add-PillTo $card "Files saved" 'Bad' "last attempt failed -- $($state.LastBackupError)"
    } else {
        $when = Format-FriendlyDateTime ([datetime]$state.LastBackupAt)
        Add-PillTo $card "Files saved" 'Good' $when
    }

    # Verify
    if (-not $state.LastVerifyAt) {
        Add-PillTo $card "Backup health checked" 'Idle' "not yet checked"
    } elseif ($state.LastVerifyOk -eq $false) {
        Add-PillTo $card "Backup health checked" 'Bad' "last check failed"
    } else {
        $when = Format-FriendlyDateTime ([datetime]$state.LastVerifyAt)
        Add-PillTo $card "Backup health checked" 'Good' $when
    }

    # Test restore
    if (-not $state.LastTestRestoreAt) {
        Add-PillTo $card "Restore tested" 'Idle' "not yet tested"
    } elseif ($state.LastTestRestoreOk -eq $false) {
        Add-PillTo $card "Restore tested" 'Bad' "last test failed"
    } else {
        $when = Format-FriendlyDateTime ([datetime]$state.LastTestRestoreAt)
        Add-PillTo $card "Restore tested" 'Good' $when
    }

    # Next scheduled run
    $nextLabel = New-Object System.Windows.Forms.Label
    $nextLabel.Font      = $Font.Heading
    $nextLabel.ForeColor = $Theme.Text
    $nextLabel.Text      = "What's coming up"
    $nextLabel.AutoSize  = $true
    $nextLabel.Location  = New-Object System.Drawing.Point(25, 310)
    $form.Controls.Add($nextLabel)

    $nextCard = New-Object System.Windows.Forms.Panel
    $nextCard.Location = New-Object System.Drawing.Point(25, 340)
    $nextCard.Size     = New-Object System.Drawing.Size(610, 130)
    $nextCard.BackColor = $Theme.Card
    $nextCard.Padding   = New-Object System.Windows.Forms.Padding(20, 14, 20, 14)
    $nextCard.BorderStyle = 'FixedSingle'
    $form.Controls.Add($nextCard)

    $nextText = New-Object System.Windows.Forms.Label
    $nextText.Font      = $Font.Body
    $nextText.ForeColor = $Theme.Text
    $nextText.AutoSize  = $false
    $nextText.Dock      = 'Fill'
    try {
        $tasks = Get-ScheduledTask -TaskPath '\DesktopMemoryNode\' -ErrorAction Stop | Sort-Object TaskName
        $lines = @()
        foreach ($t in $tasks) {
            $info = Get-ScheduledTaskInfo -TaskPath '\DesktopMemoryNode\' -TaskName $t.TaskName
            $when = Format-FriendlyFutureDateTime $info.NextRunTime
            $friendlyName = switch ($t.TaskName) {
                'Backup'      { "Save your files" }
                'Forget'      { "Tidy up old saves" }
                'Verify'      { "Check the backup is healthy" }
                'TestRestore' { "Test that restore works" }
                default       { $t.TaskName }
            }
            $lines += ("  - {0,-32} {1}" -f $friendlyName, $when)
        }
        $nextText.Text = ($lines -join "`r`n")
    } catch {
        $nextText.Text = "  (Couldn't read the schedule.)"
    }
    $nextCard.Controls.Add($nextText)

    # Action buttons row
    $actionsLabel = New-Object System.Windows.Forms.Label
    $actionsLabel.Font      = $Font.Heading
    $actionsLabel.ForeColor = $Theme.Text
    $actionsLabel.Text      = "What would you like to do?"
    $actionsLabel.AutoSize  = $true
    $actionsLabel.Location  = New-Object System.Drawing.Point(25, 480)
    $form.Controls.Add($actionsLabel)

    $btnSave = New-PrimaryButton -Text "Save my files now" -Width 180 -Height 42
    $btnSave.Location = New-Object System.Drawing.Point(25, 515)
    $btnSave.Add_Click({ $form.Close(); Start-ManualBackup }.GetNewClosure())
    $form.Controls.Add($btnSave)

    $btnBrowse = New-PrimaryButton -Text "See what's been saved" -Width 200 -Height 42
    $btnBrowse.Location = New-Object System.Drawing.Point(215, 515)
    $btnBrowse.Add_Click({ $form.Close(); Show-SnapshotsForm }.GetNewClosure())
    $form.Controls.Add($btnBrowse)

    $btnTest = New-PrimaryButton -Text "Test restore" -Width 130 -Height 42
    $btnTest.Location = New-Object System.Drawing.Point(425, 515)
    $btnTest.Add_Click({ $form.Close(); Start-TestRestore }.GetNewClosure())
    $form.Controls.Add($btnTest)

    # Close button
    $closeBtn = New-SecondaryButton -Text "Close" -Width 80 -Height 42
    $closeBtn.Location = New-Object System.Drawing.Point(565, 515)
    $closeBtn.Add_Click({ $form.Close() }.GetNewClosure())
    $form.AcceptButton = $closeBtn
    $form.Controls.Add($closeBtn)

    Add-Footer -Form $form -Y 580

    $form.ShowDialog() | Out-Null
}

# =====================================================================================
# SNAPSHOTS browser
# =====================================================================================

function Show-SnapshotsForm {
    $form = New-MemoryForm -Title "Files saved to your Memory Box" -Width 1000 -Height 640

    $hero = New-Object System.Windows.Forms.Label
    $hero.Text      = "Your saved files"
    $hero.Font      = $Font.Hero
    $hero.ForeColor = $Theme.Primary
    $hero.AutoSize  = $true
    $hero.Location  = New-Object System.Drawing.Point(20, 18)
    $form.Controls.Add($hero)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text      = "Pick a save point on the left to see what's in it."
    $sub.Font      = $Font.Body
    $sub.ForeColor = $Theme.TextMuted
    $sub.AutoSize  = $true
    $sub.Location  = New-Object System.Drawing.Point(22, 60)
    $form.Controls.Add($sub)

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Location          = New-Object System.Drawing.Point(20, 95)
    $split.Size              = New-Object System.Drawing.Size(950, 460)
    $split.Orientation       = 'Vertical'
    $split.SplitterDistance  = 360
    $split.BackColor         = $Theme.Card
    $form.Controls.Add($split)

    # Left: snapshot ListView
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Dock          = 'Fill'
    $listView.View          = 'Details'
    $listView.FullRowSelect = $true
    $listView.MultiSelect   = $false
    $listView.Font          = $Font.Body
    $listView.Columns.Add('When',   180) | Out-Null
    $listView.Columns.Add('Kind',   90)  | Out-Null
    $listView.Columns.Add('ID',     80)  | Out-Null
    $split.Panel1.Controls.Add($listView)

    $leftStatus = New-Object System.Windows.Forms.Label
    $leftStatus.Dock       = 'Bottom'
    $leftStatus.Height     = 24
    $leftStatus.Font       = $Font.Small
    $leftStatus.ForeColor  = $Theme.TextMuted
    $leftStatus.Text       = "Loading..."
    $leftStatus.TextAlign  = 'MiddleCenter'
    $split.Panel1.Controls.Add($leftStatus)

    # Right: TreeView of files in selected snapshot
    $treeView = New-Object System.Windows.Forms.TreeView
    $treeView.Dock = 'Fill'
    $treeView.Font = $Font.Mono
    $treeView.HideSelection = $false
    $split.Panel2.Controls.Add($treeView)

    $rightStatus = New-Object System.Windows.Forms.Label
    $rightStatus.Dock      = 'Bottom'
    $rightStatus.Height    = 24
    $rightStatus.Font      = $Font.Small
    $rightStatus.ForeColor = $Theme.TextMuted
    $rightStatus.Text      = "Pick a save point on the left."
    $rightStatus.TextAlign = 'MiddleCenter'
    $split.Panel2.Controls.Add($rightStatus)

    # Populate snapshots
    $form.Add_Shown({
        try {
            $raw = Invoke-Restic snapshots --json 2>$null
            if (-not $raw) { $leftStatus.Text = "No save points yet."; return }
            $snaps = @(($raw | Out-String).Trim() | ConvertFrom-Json)
            if ($snaps.Count -eq 0) { $leftStatus.Text = "No save points yet."; return }
            $sorted = $snaps | Sort-Object @{Expression={[datetime]$_.time}} -Descending
            foreach ($s in $sorted) {
                $kind = if ($s.tags -contains 'manual')    { 'You asked' }
                         elseif ($s.tags -contains 'scheduled') { 'Auto-save' }
                         else { (($s.tags) -join ',') }
                $when = Format-FriendlyDateTime ([datetime]$s.time)
                $item = New-Object System.Windows.Forms.ListViewItem ($when)
                [void]$item.SubItems.Add($kind)
                [void]$item.SubItems.Add($s.short_id)
                $item.Tag = $s.id
                [void]$listView.Items.Add($item)
            }
            $leftStatus.Text = "$($sorted.Count) save point$(if ($sorted.Count -eq 1) {''} else {'s'})"
        } catch {
            $leftStatus.Text = "Couldn't load: " + $_.Exception.Message
        }
    }.GetNewClosure())

    # On selection: populate file tree
    $listView.Add_SelectedIndexChanged({
        $treeView.Nodes.Clear()
        if ($listView.SelectedItems.Count -eq 0) { return }
        $sid = $listView.SelectedItems[0].Tag
        $rightStatus.Text = "Loading files..."
        $treeView.SuspendLayout()
        try {
            $raw = Invoke-Restic ls --json $sid 2>$null
            if (-not $raw) { $rightStatus.Text = "(empty)"; return }
            $rootNode = $treeView.Nodes.Add("Save point $($listView.SelectedItems[0].SubItems[2].Text)")
            $rootNode.NodeFont = $Font.BodyBold
            $count = 0
            $totalSize = 0L
            foreach ($line in ($raw -split "`n")) {
                $line = $line.Trim()
                if (-not $line) { continue }
                try { $obj = $line | ConvertFrom-Json } catch { continue }
                if ($obj.struct_type -ne 'node') { continue }

                $parts = ($obj.path -split '/' | Where-Object { $_ })
                $cursor = $rootNode
                for ($i = 0; $i -lt $parts.Count; $i++) {
                    $part   = $parts[$i]
                    $isLeaf = ($i -eq $parts.Count - 1)
                    $existing = $null
                    foreach ($child in $cursor.Nodes) {
                        if ($child.Text -eq $part -or $child.Text.StartsWith("$part  ")) { $existing = $child; break }
                    }
                    if ($existing) {
                        $cursor = $existing
                    } else {
                        $label = $part
                        if ($isLeaf -and $obj.type -eq 'file') {
                            $sizeStr = if ($obj.size -ge 1MB) { '{0:N1} MB' -f ($obj.size / 1MB) }
                                       elseif ($obj.size -ge 1KB) { '{0:N0} KB' -f ($obj.size / 1KB) }
                                       else { "$($obj.size) B" }
                            $label = "$part  ($sizeStr)"
                            $totalSize += $obj.size
                        }
                        $newNode = $cursor.Nodes.Add($label)
                        $cursor = $newNode
                    }
                }
                $count++
            }
            $rootNode.Expand()
            $sizeFmt = if ($totalSize -ge 1MB) { '{0:N2} MB' -f ($totalSize / 1MB) }
                       elseif ($totalSize -ge 1KB) { '{0:N1} KB' -f ($totalSize / 1KB) }
                       else { "$totalSize B" }
            $rightStatus.Text = "$count items, total $sizeFmt"
        } catch {
            $rightStatus.Text = "Couldn't load: " + $_.Exception.Message
        } finally {
            $treeView.ResumeLayout()
        }
    }.GetNewClosure())

    Add-Footer -Form $form -Y 575

    $form.ShowDialog() | Out-Null
}

# =====================================================================================
# Confirmation dialogs (manual backup, test restore)
# =====================================================================================

function Confirm-ManualBackup {
    $form = New-MemoryForm -Title "Save your files now?" -Width 480 -Height 280 -FixedSize

    $hero = New-Object System.Windows.Forms.Label
    $hero.Text      = "Save my files now"
    $hero.Font      = $Font.Hero
    $hero.ForeColor = $Theme.Primary
    $hero.AutoSize  = $true
    $hero.Location  = New-Object System.Drawing.Point(25, 22)
    $form.Controls.Add($hero)

    $body = New-Object System.Windows.Forms.Label
    $body.Text = @"
This will save a fresh copy of your files to the
backup box right now (in addition to the automatic
nightly save).

It usually takes a few minutes. You'll see a
notification when it's done.
"@
    $body.Font      = $Font.Body
    $body.ForeColor = $Theme.Text
    $body.AutoSize  = $true
    $body.Location  = New-Object System.Drawing.Point(25, 75)
    $form.Controls.Add($body)

    $okBtn = New-PrimaryButton -Text "Yes, save now" -Width 150
    $okBtn.Location = New-Object System.Drawing.Point(170, 200)
    $okBtn.DialogResult = 'OK'
    $form.AcceptButton = $okBtn
    $form.Controls.Add($okBtn)

    $cancelBtn = New-SecondaryButton -Text "Cancel" -Width 100
    $cancelBtn.Location = New-Object System.Drawing.Point(330, 200)
    $cancelBtn.DialogResult = 'Cancel'
    $form.CancelButton = $cancelBtn
    $form.Controls.Add($cancelBtn)

    return ($form.ShowDialog() -eq 'OK')
}

function Start-ManualBackup {
    if (-not (Confirm-ManualBackup)) { return }
    $script = Join-Path $repoRoot 'windows\agent\Invoke-Backup.ps1'
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script`"",'-Tag','manual') `
        -WindowStyle Hidden
    Send-MemoryboxToast -Title "Saving your files" -Body "I'm saving a fresh copy of your files to the backup box. I'll let you know when I'm done." -Level Info
}

function Confirm-TestRestore {
    $disp = Get-DmnDisplayConfig
    $tech = if ($disp.TechName) { $disp.TechName } else { 'tech support' }
    $form = New-MemoryForm -Title "Make sure I can get my files back" -Width 520 -Height 320 -FixedSize

    $hero = New-Object System.Windows.Forms.Label
    $hero.Text      = "Test the restore"
    $hero.Font      = $Font.Hero
    $hero.ForeColor = $Theme.Primary
    $hero.AutoSize  = $true
    $hero.Location  = New-Object System.Drawing.Point(25, 22)
    $form.Controls.Add($hero)

    $body = New-Object System.Windows.Forms.Label
    $body.Text = @"
This grabs one of your files from the backup box
and checks that it comes back perfectly. Nothing
on your computer is changed -- it's just a test.

You'll need the password $tech set up. If you
don't have it written down, ask $tech.
"@
    $body.Font      = $Font.Body
    $body.ForeColor = $Theme.Text
    $body.AutoSize  = $true
    $body.Location  = New-Object System.Drawing.Point(25, 75)
    $form.Controls.Add($body)

    $okBtn = New-PrimaryButton -Text "I have the password" -Width 200
    $okBtn.Location = New-Object System.Drawing.Point(160, 240)
    $okBtn.DialogResult = 'OK'
    $form.AcceptButton = $okBtn
    $form.Controls.Add($okBtn)

    $cancelBtn = New-SecondaryButton -Text "Cancel" -Width 100
    $cancelBtn.Location = New-Object System.Drawing.Point(370, 240)
    $cancelBtn.DialogResult = 'Cancel'
    $form.CancelButton = $cancelBtn
    $form.Controls.Add($cancelBtn)

    return ($form.ShowDialog() -eq 'OK')
}

function Show-PasswordPromptForm {
    <#
    .SYNOPSIS
    Modal WinForms password prompt. Returns the typed password as a string, or $null if cancelled.
    #>
    param([string]$Reason = "Type the encryption password:")

    $form = New-MemoryForm -Title "Memory Box -- type your password" -Width 480 -Height 260 -FixedSize

    $hero = New-Object System.Windows.Forms.Label
    $hero.Text      = "Type your password"
    $hero.Font      = $Font.Hero
    $hero.ForeColor = $Theme.Primary
    $hero.AutoSize  = $true
    $hero.Location  = New-Object System.Drawing.Point(25, 22)
    $form.Controls.Add($hero)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text      = $Reason
    $sub.Font      = $Font.Body
    $sub.ForeColor = $Theme.Text
    $sub.AutoSize  = $true
    $sub.Location  = New-Object System.Drawing.Point(25, 75)
    $form.Controls.Add($sub)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(25, 110)
    $tb.Size     = New-Object System.Drawing.Size(420, 28)
    $tb.Font     = $Font.Body
    $tb.UseSystemPasswordChar = $true
    $form.Controls.Add($tb)

    $script:typedPassword = $null

    $okBtn = New-PrimaryButton -Text "OK" -Width 110
    $okBtn.Location = New-Object System.Drawing.Point(225, 175)
    $okBtn.Add_Click({
        $script:typedPassword = $tb.Text
        $form.Close()
    }.GetNewClosure())
    $form.AcceptButton = $okBtn
    $form.Controls.Add($okBtn)

    $cancelBtn = New-SecondaryButton -Text "Cancel" -Width 110
    $cancelBtn.Location = New-Object System.Drawing.Point(345, 175)
    $cancelBtn.Add_Click({ $script:typedPassword = $null; $form.Close() }.GetNewClosure())
    $form.CancelButton = $cancelBtn
    $form.Controls.Add($cancelBtn)

    $form.Add_Shown({ $tb.Focus() | Out-Null }.GetNewClosure())

    $form.ShowDialog() | Out-Null
    return $script:typedPassword
}

function Show-TestRestoreResult {
    param([string]$Title, [string]$Body, [ValidateSet('Success','Error')][string]$Kind = 'Success')

    $form = New-MemoryForm -Title "Memory Box" -Width 520 -Height 280 -FixedSize

    $accent = if ($Kind -eq 'Success') { $Theme.Success } else { $Theme.Danger }

    $hero = New-Object System.Windows.Forms.Label
    $hero.Text      = $Title
    $hero.Font      = $Font.Hero
    $hero.ForeColor = $accent
    $hero.AutoSize  = $true
    $hero.Location  = New-Object System.Drawing.Point(25, 22)
    $form.Controls.Add($hero)

    $body = New-Object System.Windows.Forms.Label
    $body.Text      = $Body
    $body.Font      = $Font.Body
    $body.ForeColor = $Theme.Text
    $body.AutoSize  = $false
    $body.Size      = New-Object System.Drawing.Size(465, 100)
    $body.Location  = New-Object System.Drawing.Point(25, 75)
    $form.Controls.Add($body)

    $okBtn = New-PrimaryButton -Text "OK" -Width 110
    $okBtn.Location = New-Object System.Drawing.Point(380, 200)
    $okBtn.Add_Click({ $form.Close() }.GetNewClosure())
    $form.AcceptButton = $okBtn
    $form.Controls.Add($okBtn)

    $form.ShowDialog() | Out-Null
}

function Start-TestRestore {
    if (-not (Confirm-TestRestore)) { return }

    $password = Show-PasswordPromptForm -Reason "Type the password to verify the backup is healthy."
    if (-not $password) { return }

    # Set the override and run the test-restore logic inline. We use Invoke-Restic
    # directly so all output is captured in the tray process and we can show a
    # result dialog -- no PowerShell window ever appears.
    Set-ResticPasswordOverride -Password $password
    $scratch = Join-Path $env:TEMP "dmn-tray-test-$([guid]::NewGuid().Guid.Substring(0,8))"
    try {
        Connect-MemoryboxSmb

        # Newest snapshot
        $rawSnaps = Invoke-Restic snapshots --json 2>$null
        $snaps    = if ($rawSnaps) { @(($rawSnaps | Out-String).Trim() | ConvertFrom-Json) } else { @() }
        if ($snaps.Count -eq 0) {
            Show-TestRestoreResult -Title "No snapshots yet" -Body "There aren't any backups in your Memory Box to test. Save your files at least once first." -Kind Error
            return
        }
        $newest = $snaps | Sort-Object @{Expression={[datetime]$_.time}} -Descending | Select-Object -First 1

        # Small test file
        $rawLs = Invoke-Restic ls --json $newest.id 2>$null
        $files = @()
        foreach ($line in ($rawLs -split "`n")) {
            $line = $line.Trim(); if (-not $line) { continue }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.struct_type -eq 'node' -and $obj.type -eq 'file' -and $obj.size -gt 0 -and $obj.size -le 1MB) {
                $files += $obj
            }
        }
        if ($files.Count -eq 0) {
            Show-TestRestoreResult -Title "No file to test with" -Body "Couldn't find a small file to test with. Try saving more files first." -Kind Error
            return
        }
        $testFile = $files | Get-Random
        New-Item -ItemType Directory -Path $scratch -Force | Out-Null
        $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            Invoke-Restic restore $newest.id --target $scratch --include $testFile.path 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevPref }

        $restored = Get-ChildItem -Path $scratch -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -eq $testFile.size } | Select-Object -First 1
        if (-not $restored) {
            # Most likely cause: wrong password
            Show-TestRestoreResult -Title "Test didn't work" -Body "Couldn't decrypt and recover a file from the backup box. The password might be wrong, or the backup is unreachable.  $(Get-DmnSupportLine)" -Kind Error
            return
        }

        # Success
        Set-NodeState -Updates @{
            LastTestRestoreAt = (Get-Date).ToString('o')
            LastTestRestoreOk = $true
        }
        $size = $restored.Length
        $msg  = "I successfully decrypted and recovered a $size-byte file from your Memory Box. Your password is correct and the backup is healthy."
        Show-TestRestoreResult -Title "Test passed" -Body $msg -Kind Success
    } catch {
        Show-TestRestoreResult -Title "Test didn't work" -Body "Something went wrong: $($_.Exception.Message).  $(Get-DmnSupportLine)" -Kind Error
    } finally {
        Clear-ResticPasswordOverride
        $password = $null
        if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
    }
}

# =====================================================================================
# ADVANCED -- settings (technical) and dev tools
# =====================================================================================

function Show-SettingsForm {
    $form = New-MemoryForm -Title "Connection settings (advanced)" -Width 580 -Height 480 -FixedSize

    $hero = New-Object System.Windows.Forms.Label
    $hero.Text      = "Connection settings"
    $hero.Font      = $Font.Hero
    $hero.ForeColor = $Theme.Primary
    $hero.AutoSize  = $true
    $hero.Location  = New-Object System.Drawing.Point(25, 22)
    $form.Controls.Add($hero)

    $warn = New-Object System.Windows.Forms.Label
    $warn.Text      = "Tech-support tools. Don't change these unless you know what you're doing."
    $warn.Font      = $Font.Small
    $warn.ForeColor = $Theme.Warning
    $warn.AutoSize  = $true
    $warn.Location  = New-Object System.Drawing.Point(25, 70)
    $form.Controls.Add($warn)

    $fields = @(
        @{ Name='MEMORYBOX_HOST';      Label='Backup box host'; Secret=$false },
        @{ Name='MEMORYBOX_PORT';      Label='Port';            Secret=$false },
        @{ Name='MEMORYBOX_USER';      Label='Username';        Secret=$false },
        @{ Name='MEMORYBOX_PASSWORD';  Label='Box password';    Secret=$true  },
        @{ Name='MEMORYBOX_NODE_NAME'; Label='This node name';  Secret=$false },
        @{ Name='enc_pswd';            Label='Encryption pwd';  Secret=$true  }
    )
    $textBoxes = @{}
    $y = 110
    foreach ($f in $fields) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text     = $f.Label
        $lbl.Font     = $Font.Body
        $lbl.Location = New-Object System.Drawing.Point(25, ($y + 4))
        $lbl.Size     = New-Object System.Drawing.Size(150, 24)
        $form.Controls.Add($lbl)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(180, $y)
        $tb.Size     = New-Object System.Drawing.Size(360, 24)
        $tb.Font     = $Font.Body
        if ($f.Secret) { $tb.UseSystemPasswordChar = $true }
        $current = [Environment]::GetEnvironmentVariable($f.Name, 'User')
        $tb.Text = if ($f.Secret -and $current) { '<unchanged>' } elseif ($current) { $current } else { '' }
        $form.Controls.Add($tb)
        $textBoxes[$f.Name] = $tb
        $y += 36
    }

    $saveBtn = New-PrimaryButton -Text "Save changes" -Width 140
    $saveBtn.Location = New-Object System.Drawing.Point(290, 380)
    $saveBtn.Add_Click({
        $changed = 0
        foreach ($f in $fields) {
            $v = $textBoxes[$f.Name].Text
            if ($f.Secret -and $v -eq '<unchanged>') { continue }
            if ([string]::IsNullOrWhiteSpace($v))    { continue }
            if ($v -cne [Environment]::GetEnvironmentVariable($f.Name, 'User')) {
                [Environment]::SetEnvironmentVariable($f.Name, $v, 'User')
                $changed++
            }
        }
        Send-MemoryboxToast -Title "Settings saved" -Body "$changed value(s) updated. Open new terminals or restart background services to pick them up." -Level Success
        $form.Close()
    }.GetNewClosure())
    $form.AcceptButton = $saveBtn
    $form.Controls.Add($saveBtn)

    $cancelBtn = New-SecondaryButton -Text "Cancel" -Width 100
    $cancelBtn.Location = New-Object System.Drawing.Point(440, 380)
    $cancelBtn.Add_Click({ $form.Close() }.GetNewClosure())
    $form.CancelButton = $cancelBtn
    $form.Controls.Add($cancelBtn)

    Add-Footer -Form $form -Y 425

    $form.ShowDialog() | Out-Null
}

function Open-NasInBrowser {
    $cfg = Get-MemoryboxConfig
    if ($cfg.BaseUrl) { Start-Process $cfg.BaseUrl }
}

function Open-LatestLog {
    $logDir = Join-Path (Get-DmnStateRoot) 'logs'
    $latest = Get-ChildItem -Path $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Start-Process notepad.exe -ArgumentList "`"$($latest.FullName)`"" }
    else { Send-MemoryboxToast -Title "No activity yet" -Body "Backups haven't run yet -- there's nothing to show." -Level Info }
}

function Open-Preflight {
    $script = Join-Path $repoRoot 'windows\setup\Test-Setup.ps1'
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',"`"$script`"")
}

# =====================================================================================
# Tray menu wiring
# =====================================================================================

function Add-Item($menu, $text, $action) {
    $i = $menu.Items.Add($text)
    $i.add_Click($action)
    return $i
}

# Main menu (mom-friendly)
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = $Font.Body

[void](Add-Item $menu 'How are my backups doing?' { Show-StatusForm })
[void](Add-Item $menu 'Save my files now'         { Start-ManualBackup })
[void](Add-Item $menu 'See what''s been saved'    { Show-SnapshotsForm })
[void](Add-Item $menu 'Make sure I can get my files back' { Start-TestRestore })

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Advanced submenu (tech-support tools)
$advanced = New-Object System.Windows.Forms.ToolStripMenuItem 'Advanced'
[void]($advanced.DropDownItems.Add('Connection settings...')).add_Click({ Show-SettingsForm })
[void]($advanced.DropDownItems.Add('Open backup box website')).add_Click({ Open-NasInBrowser })
[void]($advanced.DropDownItems.Add('See activity log')).add_Click({ Open-LatestLog })
[void]($advanced.DropDownItems.Add('Run preflight checks')).add_Click({ Open-Preflight })
[void]$menu.Items.Add($advanced)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

[void](Add-Item $menu 'Hide tray icon' {
    if ($script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() }
    [System.Windows.Forms.Application]::Exit()
})

# If invoked with -ShowStatus / -ShowSnapshots, just open that form and exit (no tray).
if ($ShowStatus) {
    Write-DebugLine "Entering -ShowStatus path"
    try {
        Show-StatusForm
        Write-DebugLine "Show-StatusForm returned cleanly"
    } catch {
        Write-DebugLine "Show-StatusForm THREW: $($_.Exception.Message)"
        Write-DebugLine "  Stack: $($_.ScriptStackTrace)"
        [System.Windows.Forms.MessageBox]::Show(
            "Couldn't open the dashboard.`r`n`r`nError: $($_.Exception.Message)`r`n`r`nDebug log: $($script:DebugLog)",
            'Memory Box',
            'OK',
            'Error'
        ) | Out-Null
    }
    return
}
if ($ShowSnapshots) {
    Show-SnapshotsForm
    return
}

# Single-instance guard: prevent multiple tray icons from accumulating.
# Use a session-scoped mutex (no Global\ prefix) so each interactive session
# gets one tray, not one per-machine.
$script:Mutex = New-Object System.Threading.Mutex $false, 'DesktopMemoryNode-Tray'
$haveMutex = $false
try { $haveMutex = $script:Mutex.WaitOne(0, $false) } catch { $haveMutex = $false }
if (-not $haveMutex) {
    # Another tray is already running; just exit silently.
    return
}

# Tray icon
$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon   = New-MemoryBoxIcon
$script:NotifyIcon.Icon              = $script:TrayIcon
$disp = Get-DmnDisplayConfig
$tipName = if ($disp.UserName) { "$($disp.UserName)'s Memory Box" } else { 'Memory Box' }
$script:NotifyIcon.Text              = $tipName
$script:NotifyIcon.ContextMenuStrip  = $menu
$script:NotifyIcon.Visible           = $true

# Left-click opens Status. Wire up multiple events because NotifyIcon click
# behavior is inconsistent on different Windows builds:
#   - add_Click fires on left single-click on most builds
#   - add_MouseUp + button check is the most reliable cross-build path
#   - add_DoubleClick is a backup for users who instinctively double-click tray icons
$leftClickHandler = {
    param($sender, $e)
    $btn = $e.Button
    if ($btn -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-StatusForm
    }
}
$script:NotifyIcon.add_MouseUp($leftClickHandler)
$script:NotifyIcon.add_DoubleClick({ Show-StatusForm })

# First-launch welcome
$state = Get-NodeState
if (-not $state.WelcomeShown) {
    Show-WelcomeForm
    Set-NodeState -Updates @{ WelcomeShown = $true }
}

# Toast on missing-vars at launch
$missing = Get-MissingMemoryboxVars
if ($missing.Count -gt 0) {
    Send-MemoryboxToast -Title "Setup isn't finished" `
        -Body ("Missing: " + ($missing -join ', ') + ". Right-click the tray icon -> Advanced -> Connection settings.") `
        -Level Warning
}

[System.Windows.Forms.Application]::Run()
