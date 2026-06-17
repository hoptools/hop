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
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);

    public static int[] WindowSize(IntPtr h) {
        RECT r;
        if (!GetWindowRect(h, out r)) return new int[] { 0, 0 };
        return new int[] { r.Right - r.Left, r.Bottom - r.Top };
    }
    public static int[] WindowRect(IntPtr h) {
        RECT r;
        if (!GetWindowRect(h, out r)) return new int[] { 0, 0, 0, 0 };
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }
    // The largest visible top-level window owned by pid — used when Process.MainWindowHandle is still 0
    // (common right after launch, and for some toolkits' window types).
    public static IntPtr FindMainWindow(uint pid) {
        IntPtr best = IntPtr.Zero; int bestArea = -1;
        EnumWindows((h, lp) => {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == pid && IsWindowVisible(h)) {
                RECT r;
                if (GetWindowRect(h, out r)) {
                    int a = (r.Right - r.Left) * (r.Bottom - r.Top);
                    if (a > bestArea) { bestArea = a; best = h; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
"@

# Is a captured bitmap effectively blank? Sample a coarse grid and count distinct colors: an unrendered
# window is a single flat color (1), while any real page (the sidebar tree alone has dozens) blows past
# the threshold. Cheap (early-exits) and far more reliable than a fixed sleep for "did it draw yet".
function Test-Blank($bmp) {
    $seen = @{}
    $sx = [Math]::Max(1, [int]($bmp.Width / 24))
    $sy = [Math]::Max(1, [int]($bmp.Height / 24))
    for ($y = 0; $y -lt $bmp.Height; $y += $sy) {
        for ($x = 0; $x -lt $bmp.Width; $x += $sx) {
            $c = $bmp.GetPixel($x, $y)
            $seen[($c.R -shl 16) -bor ($c.G -shl 8) -bor $c.B] = $true
            if ($seen.Count -ge 5) { return $false }   # enough variety -> real content
        }
    }
    return $true   # < 5 distinct colors across the whole grid -> effectively blank
}

# PrintWindow into a PowerShell-side bitmap (works even when the window is off-screen / larger than the
# desktop). PW_RENDERFULLCONTENT (flag 2) captures DirectComposition/WinUI content too.
function Grab-PrintWindow([IntPtr]$hWnd) {
    $size = [HopWin]::WindowSize($hWnd); $w = $size[0]; $h = $size[1]
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][HopWin]::PrintWindow($hWnd, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    return $bmp
}

# Copy the window's on-screen rectangle (clamped to the virtual screen) — a fallback for the rare window
# whose composited content PrintWindow can't read; needs the window foregrounded + on-screen (done below).
function Grab-ScreenRegion([IntPtr]$hWnd) {
    $r = [HopWin]::WindowRect($hWnd); $x = $r[0]; $y = $r[1]; $w = $r[2]; $h = $r[3]
    if ($w -le 0 -or $h -le 0) { return $null }
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($x -lt $vs.X) { $x = $vs.X }; if ($y -lt $vs.Y) { $y = $vs.Y }
    $w = [Math]::Min($w, $vs.Right - $x); $h = [Math]::Min($h, $vs.Bottom - $y)
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    return $bmp
}

# Capture a launched app's main window, robustly: wait for the window (even if MainWindowHandle is slow to
# populate), bring it to front at (0,0), then keep grabbing (PrintWindow, then screen-region) until the
# result is non-blank. Saves only a non-blank shot — returns $false rather than ever writing an empty one.
function Capture-Window([System.Diagnostics.Process]$proc, $path) {
    $hWnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 60; $i++) {                 # up to ~15s for the window to appear
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { return $false }
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $hWnd = $proc.MainWindowHandle; break }
        $h = [HopWin]::FindMainWindow([uint32]$proc.Id)
        if ($h -ne [IntPtr]::Zero) { $hWnd = $h; break }
    }
    if ($hWnd -eq [IntPtr]::Zero) { return $false }

    [void][HopWin]::ShowWindow($hWnd, 5)            # SW_SHOW
    [void][HopWin]::SetWindowPos($hWnd, [IntPtr]::Zero, 0, 0, 0, 0, (0x0001 -bor 0x0040))  # HWND_TOP, NOSIZE|SHOWWINDOW
    [void][HopWin]::SetForegroundWindow($hWnd)

    for ($a = 0; $a -lt 20; $a++) {                 # up to ~12s of redraw attempts
        Start-Sleep -Milliseconds 600
        # PrintWindow first (works off-screen / for composited content); screen-region only if it's blank.
        foreach ($grab in 'Grab-PrintWindow', 'Grab-ScreenRegion') {
            $bmp = & $grab $hWnd
            if ($null -eq $bmp) { continue }
            $blank = Test-Blank $bmp
            if (-not $blank) {
                $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); return $true
            }
            $bmp.Dispose()
        }
    }
    return $false                                   # never rendered content -> don't write a blank
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
            if (Capture-Window $proc $out) { Write-Host "  OK $tk / $pg"; $ok++ }
            else { Write-Host "  FAIL (no non-blank window) $tk / $pg"; $bad++ }
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
