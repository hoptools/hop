# Copyright 2026
# SPDX-License-Identifier: MPL-2.0
#
# Windows counterpart of screenshot-playgrounds.sh: launch the HopUI demo for one or more toolkit
# backends, open each playground (via HOP_PLAYGROUND_ID), and screenshot every page into <OutDir>.
#
#   Usage: powershell -File scripts/ci/screenshot-playgrounds.ps1 -OutDir <dir> -Toolkits qt,winui
#     toolkit ∈ qt | winui   (maps to hop-demo-qt.exe / hop-demo-winui.exe)
#
# Captures the primary screen (the demo renders onto the runner's interactive desktop). Best-effort:
# failures are logged but never fail the job; the build/test gate is what matters. Always exits 0.

param(
    [Parameter(Mandatory = $true)][string]   $OutDir,
    [Parameter(Mandatory = $true)][string[]] $Toolkits
)
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..\..")
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Exec-For($tk) {
    switch ($tk) {
        "gtk4"    { "hop-demo-gtk4" }
        "appkit"  { "hop-demo-appkit" }
        "qt"      { "hop-demo-qt" }
        "swiftui" { "hop-demo-native" }
        "winui"   { "hop-demo-winui" }
        default   { $null }
    }
}

# Playground ids = the cases of `enum Playground: String` in the shared demo ContentView.
$content = Get-Content "Demo/ContentView.swift" -Raw
$block = [regex]::Match($content, 'enum Playground: String[\s\S]*?var title').Value
$pgs = [regex]::Matches($block, '(?m)^\s*case (.+)$') |
    ForEach-Object { $_.Groups[1].Value -replace '//.*', '' } |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' }
if (-not $pgs) { Write-Host "no playgrounds parsed"; exit 0 }
Write-Host "Backends: $($Toolkits -join ', ')"
Write-Host "Playgrounds ($($pgs.Count)): $($pgs -join ', ')"

$bin = (swift build --show-bin-path).Trim()
Write-Host "Binaries: $bin"

# Uniform window size for screenshots; the Qt/AppKit/native backends honor HOP_WINDOW_SIZE at window
# creation (1280x800 is the standard Mac marketing size). WinUI keeps its shim default.
if (-not $env:HOP_WINDOW_SIZE) { $env:HOP_WINDOW_SIZE = "1280x800" }
Write-Host "Window size: $($env:HOP_WINDOW_SIZE)"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# Capture JUST a window (not the whole desktop): PrintWindow renders the window's own content to a
# bitmap, so it works even when the window is larger than the runner's screen or partly off-screen.
# Only the Win32 P/Invoke lives in C# here — no System.Drawing types, so Add-Type doesn't need to
# reference System.Drawing.Common (whose Bitmap/Graphics forwarding breaks `Add-Type -TypeDefinition`
# on PowerShell 7 / .NET). The bitmap is built in PowerShell below, where the forward resolves fine.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class HopWin {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    public static int[] WindowSize(IntPtr hWnd) {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return new int[] { 0, 0 };
        return new int[] { r.Right - r.Left, r.Bottom - r.Top };
    }
}
"@

# Whole-screen fallback when a window handle never appears.
function Capture-Screen($path) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

# Capture an app's main window by handle (PrintWindow into a PowerShell-side bitmap); $true on success.
function Capture-Window([IntPtr]$hWnd, $path) {
    $size = [HopWin]::WindowSize($hWnd)
    $w = $size[0]; $h = $size[1]
    if ($w -le 0 -or $h -le 0) { return $false }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][HopWin]::PrintWindow($hWnd, $hdc, 2)   # PW_RENDERFULLCONTENT (GPU/DWM-composited windows)
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $true
}

# The WinUI demo is a framework-dependent, *unpackaged* Windows App SDK app, so launching it needs two
# things the build doesn't provide on its own:
#   1. hop-demo-winui.exe statically imports Microsoft.WindowsAppRuntime.Bootstrap.dll. setup-winui.ps1
#      stages that DLL into .winui/, but it isn't next to the freshly-built exe, so the loader fails with
#      "Microsoft.WindowsAppRuntime.Bootstrap.dll was not found". Copy it next to the exe (searched first).
#   2. At startup the CWinUI shim calls MddBootstrapInitialize2(0x00010006, …) to load the *installed*
#      Windows App Runtime 1.6 framework; with OnNoMatch_ShowUI it pops an install dialog if it's absent.
#      Install the 1.6 runtime so the bootstrapper succeeds and the real UI renders.
function Ensure-WinUIRuntime($bin) {
    $boot = "Microsoft.WindowsAppRuntime.Bootstrap.dll"
    $src = Join-Path (Get-Location) ".winui\$boot"
    if (Test-Path $src) {
        Copy-Item -Force $src (Join-Path $bin $boot)
        Write-Host "WinUI: copied $boot next to the demo exe"
    } else {
        Write-Host "WinUI: WARNING $src not found - run scripts/setup-winui.ps1 first"
    }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    # Stable-channel redistributable; minVersion is 0 in the shim so any installed 1.6.x satisfies it.
    $url = "https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-$arch.exe"
    $dst = Join-Path $env:TEMP "windowsappruntimeinstall-$arch.exe"
    Write-Host "WinUI: ensuring Windows App Runtime 1.6 ($arch) via $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing
        & $dst --quiet
        Write-Host "WinUI: runtime installer exit code $LASTEXITCODE"
    } catch {
        Write-Host "WinUI: WARNING failed to install Windows App Runtime: $_"
    }
}

$ok = 0; $bad = 0
foreach ($tk in $Toolkits) {
    $exe = Exec-For $tk
    if (-not $exe) { Write-Host "unknown toolkit: $tk"; continue }
    $exePath = Join-Path $bin "$exe.exe"
    if (-not (Test-Path $exePath)) { Write-Host "skip ${tk}: $exePath not built"; continue }
    if ($tk -eq "winui") { Ensure-WinUIRuntime $bin }
    foreach ($pg in $pgs) {
        $env:HOP_PLAYGROUND_ID = $pg
        $out = Join-Path $OutDir "$($tk)__$($pg).png"
        $proc = $null
        try {
            $proc = Start-Process -FilePath $exePath -PassThru -ErrorAction Stop
            # Wait for the app's main window to appear, then capture just it (fall back to whole screen).
            $hWnd = [IntPtr]::Zero
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 250
                $proc.Refresh()
                if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $hWnd = $proc.MainWindowHandle; break }
            }
            Start-Sleep -Seconds 1   # let it finish drawing
            $shot = $false
            if ($hWnd -ne [IntPtr]::Zero) { $shot = Capture-Window $hWnd $out }
            if (-not $shot) { Capture-Screen $out }
            if (Test-Path $out) { Write-Host "  OK $tk / $pg"; $ok++ } else { Write-Host "  FAIL $tk / $pg"; $bad++ }
        } catch {
            Write-Host "  FAIL $tk / $pg : $_"; $bad++
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}

Write-Host "Captured $ok screenshot(s) ($bad failed) -> $OutDir"
Get-ChildItem $OutDir -ErrorAction SilentlyContinue | Format-Table Name, Length
exit 0
