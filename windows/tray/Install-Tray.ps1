<#
.SYNOPSIS
Installs the DesktopMemoryNode tray app to launch at login.

.DESCRIPTION
Creates a shortcut in the user's Startup folder
(%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\) that runs BackupTray.ps1
in a hidden powershell window when you log in.

Idempotent: replaces any existing shortcut.

.PARAMETER Remove
Delete the startup shortcut.

.PARAMETER LaunchNow
Also start the tray app right now (in addition to installing the shortcut).

.EXAMPLE
.\Install-Tray.ps1
Install the startup shortcut.

.EXAMPLE
.\Install-Tray.ps1 -LaunchNow
Install AND start the tray right now.

.EXAMPLE
.\Install-Tray.ps1 -Remove
Uninstall.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$LaunchNow
)

$ErrorActionPreference = 'Stop'
$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$trayScript  = Join-Path $here 'BackupTray.ps1'

# Renders the Memory Box icon at the given size as a Bitmap (32-bit ARGB):
# rounded blue square, subtle top highlight, centered white heart drawn with
# Bezier curves so it stays crisp at every resolution.
function New-MemoryBoxBitmap {
    param([int]$Size)

    $primary = [System.Drawing.Color]::FromArgb(61, 122, 174)
    $heartW  = [System.Drawing.Color]::White

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    # Rounded background
    $r       = [Math]::Max(2, [int]($Size * 0.18))
    $bgRect  = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
    $bgPath  = New-Object System.Drawing.Drawing2D.GraphicsPath
    $bgPath.AddArc($bgRect.X, $bgRect.Y, $r * 2, $r * 2, 180, 90)
    $bgPath.AddArc($bgRect.Right - $r * 2, $bgRect.Y, $r * 2, $r * 2, 270, 90)
    $bgPath.AddArc($bgRect.Right - $r * 2, $bgRect.Bottom - $r * 2, $r * 2, $r * 2, 0, 90)
    $bgPath.AddArc($bgRect.X, $bgRect.Bottom - $r * 2, $r * 2, $r * 2, 90, 90)
    $bgPath.CloseFigure()

    # Vertical gradient: a touch lighter at top for depth
    $gradTop    = [System.Drawing.Color]::FromArgb(255, 78, 145, 196)
    $gradBottom = [System.Drawing.Color]::FromArgb(255, 51, 108, 158)
    $gradBrush  = New-Object System.Drawing.Drawing2D.LinearGradientBrush $bgRect, $gradTop, $gradBottom, 90
    $g.FillPath($gradBrush, $bgPath)
    $gradBrush.Dispose()
    $bgPath.Dispose()

    # Heart drawn with cubic Beziers in unit coords, then scaled to the icon
    # Centered horizontally, sized at ~58% of the icon, slightly above center
    $cx     = $Size / 2.0
    $heartH = $Size * 0.58
    $heartW = $heartH * 1.10
    $top    = ($Size * 0.50) - ($heartH * 0.55)

    $heart = New-Object System.Drawing.Drawing2D.GraphicsPath
    # Start at bottom point of the heart
    $bottomY = $top + $heartH
    $leftX   = $cx - $heartW / 2.0
    $rightX  = $cx + $heartW / 2.0
    $midY    = $top + $heartH * 0.30      # control "valley" between lobes

    # Right side of the heart: bottom point -> right lobe top -> top-center valley
    $heart.AddBezier(
        $cx,                $bottomY,
        $cx + $heartW * 0.55, $top + $heartH * 0.65,
        $rightX,             $midY,
        $rightX,             $top + $heartH * 0.30
    )
    $heart.AddBezier(
        $rightX,             $top + $heartH * 0.30,
        $rightX,             $top - $heartH * 0.05,
        $cx + $heartW * 0.05, $top - $heartH * 0.05,
        $cx,                 $top + $heartH * 0.20
    )
    # Left side: top-center valley -> left lobe top -> bottom point
    $heart.AddBezier(
        $cx,                 $top + $heartH * 0.20,
        $cx - $heartW * 0.05, $top - $heartH * 0.05,
        $leftX,              $top - $heartH * 0.05,
        $leftX,              $top + $heartH * 0.30
    )
    $heart.AddBezier(
        $leftX,              $top + $heartH * 0.30,
        $leftX,              $midY,
        $cx - $heartW * 0.55, $top + $heartH * 0.65,
        $cx,                 $bottomY
    )
    $heart.CloseFigure()

    $heartBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillPath($heartBrush, $heart)
    $heartBrush.Dispose()
    $heart.Dispose()

    $g.Dispose()
    $bmp
}

# Saves a multi-size .ico file (PNG-compressed) so Windows uses the
# right resolution at every display scale. No more pixelated upscaling.
function Save-MemoryBoxIcon {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $pngBlobs = foreach ($s in $sizes) {
        $bmp = New-MemoryBoxBitmap -Size $s
        $ms  = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        ,@($ms.ToArray())
    }

    $fs = [System.IO.File]::Open($Path, 'Create')
    $bw = New-Object System.IO.BinaryWriter $fs
    try {
        # ICONDIR header
        $bw.Write([uint16]0)              # reserved
        $bw.Write([uint16]1)              # type: 1 = ICO
        $bw.Write([uint16]$sizes.Count)

        $entrySize  = 16
        $headerSize = 6 + $entrySize * $sizes.Count
        $offset     = $headerSize

        # ICONDIRENTRY for each image
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $s   = $sizes[$i]
            $len = $pngBlobs[$i].Length
            $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))   # width  (0 = 256)
            $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))   # height (0 = 256)
            $bw.Write([byte]0)            # color count (0 for >=8bpp)
            $bw.Write([byte]0)            # reserved
            $bw.Write([uint16]1)          # planes
            $bw.Write([uint16]32)         # bits per pixel
            $bw.Write([uint32]$len)       # size of image data
            $bw.Write([uint32]$offset)    # offset to image data
            $offset += $len
        }

        # PNG bytes for each size
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $bw.Write($pngBlobs[$i])
        }
    } finally {
        $bw.Close()
        $fs.Close()
    }
}

$iconDir  = Join-Path $env:LOCALAPPDATA 'DesktopMemoryNode'
if (-not (Test-Path $iconDir)) { New-Item -ItemType Directory -Path $iconDir -Force | Out-Null }
$iconPath = Join-Path $iconDir 'Memory-Box.ico'
Save-MemoryBoxIcon -Path $iconPath
$startupDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startMenu   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$desktopDir  = [Environment]::GetFolderPath('Desktop')

$shortcut    = Join-Path $startupDir 'Memory Box (auto-start).lnk'
$startMenuLnk = Join-Path $startMenu 'Memory Box.lnk'
$desktopLnk  = Join-Path $desktopDir 'Memory Box.lnk'

# Generate VBS launcher files. wscript.exe runs them with no console window
# at all -- no powershell.exe flash before the form appears.
function Save-VbsLauncher {
    param([string]$Path, [string[]]$ExtraPsArgs = @())

    $psExe   = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$trayScript`"") + $ExtraPsArgs
    # VBS string-escape: replace " with "" inside the joined arg string
    $cmdLine = ($argList -join ' ') -replace '"','""'
    $vbs = @"
' DesktopMemoryNode launcher -- runs PowerShell with no console flash.
Set ws = CreateObject("WScript.Shell")
ws.Run """$psExe"" $cmdLine", 0, False
"@
    [IO.File]::WriteAllText($Path, $vbs, [Text.Encoding]::ASCII)
}

$launchTrayVbs   = Join-Path $iconDir 'launch-tray.vbs'
$launchStatusVbs = Join-Path $iconDir 'launch-status.vbs'
Save-VbsLauncher -Path $launchTrayVbs
Save-VbsLauncher -Path $launchStatusVbs -ExtraPsArgs @('-ShowStatus')

function New-TrayShortcut {
    param(
        [string]$Path,
        [string]$Description,
        [string]$VbsTarget
    )
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($Path)
    $lnk.TargetPath       = "$env:WINDIR\System32\wscript.exe"
    $lnk.Arguments        = "`"$VbsTarget`""
    $lnk.WorkingDirectory = $here
    $lnk.WindowStyle      = 1
    $lnk.Description      = $Description
    $lnk.IconLocation     = $iconPath
    $lnk.Save()
}

if ($Remove) {
    foreach ($p in @($shortcut, $startMenuLnk, $desktopLnk)) {
        if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Removed: $p" -ForegroundColor Green }
    }
    return
}

if (-not (Test-Path $trayScript)) { throw "BackupTray.ps1 not found at $trayScript" }
if (-not (Test-Path $startupDir)) { throw "Startup folder not found at $startupDir" }

# Startup shortcut: launches the tray (background)
New-TrayShortcut -Path $shortcut     -Description 'Memory Box -- launches the tray at login' -VbsTarget $launchTrayVbs

# Desktop + Start Menu shortcuts: open the Status dashboard directly (no extra tray instance)
New-TrayShortcut -Path $startMenuLnk -Description 'Open Memory Box dashboard' -VbsTarget $launchStatusVbs
New-TrayShortcut -Path $desktopLnk   -Description 'Open Memory Box dashboard' -VbsTarget $launchStatusVbs

Write-Host "Installed:" -ForegroundColor Green
Write-Host "  $shortcut" -ForegroundColor DarkGray
Write-Host "  $startMenuLnk" -ForegroundColor DarkGray
Write-Host "  $desktopLnk" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Tip: right-click the desktop shortcut -> Pin to taskbar." -ForegroundColor Cyan

if ($LaunchNow) {
    Write-Host "Launching tray now..." -ForegroundColor Cyan
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`"" `
        -WorkingDirectory $here -WindowStyle Hidden
}
