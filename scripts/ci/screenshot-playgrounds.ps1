# Copyright 2026
# SPDX-License-Identifier: MPL-2.0
#
# Windows counterpart of screenshot-playgrounds.sh: launch the HopUI demo for one or more toolkit
# backends, open each playground (via HOP_PLAYGROUND_ID), and screenshot every page into <OutDir>.
#
#   Usage: powershell -File scripts/ci/screenshot-playgrounds.ps1 -OutDir <dir> -Toolkits qt,winui
#     toolkit ∈ qt | winui   (maps to hop-demo-qt.exe / hop-demo-winui.exe)
#
# Captures each demo's OWN window via PrintWindow (never the desktop or other windows). Best-effort:
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

# The demo apps live in their own package now (it depends on the root package + the HopUIComboBox component).
$Showcase = "Demos/Showcase"

# Playground ids = the cases of `enum Playground: String` in the shared demo ContentView.
$content = Get-Content "$Showcase/Shared/ContentView.swift" -Raw
$block = [regex]::Match($content, 'enum Playground: String[\s\S]*?var title').Value
$pgs = [regex]::Matches($block, '(?m)^\s*case (.+)$') |
    ForEach-Object { $_.Groups[1].Value -replace '//.*', '' } |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' }
if (-not $pgs) { Write-Host "no playgrounds parsed"; exit 0 }
Write-Host "Backends: $($Toolkits -join ', ')"
Write-Host "Playgrounds ($($pgs.Count)): $($pgs -join ', ')"

swift build --package-path $Showcase
if ($LASTEXITCODE -ne 0) { Write-Host "Showcase build failed"; exit 0 }
$bin = (swift build --package-path $Showcase --show-bin-path).Trim()
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
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY; public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels; public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight;
        public uint dmDisplayFlags, dmDisplayFrequency, dmICMMethod, dmICMIntent, dmMediaType;
        public uint dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
    // Enlarge the desktop so a 1280x800 window fits (runners default to 1024x768, which would clip a
    // screen-region capture). Returns the ChangeDisplaySettings result (0 == DISP_CHANGE_SUCCESSFUL).
    public static int SetResolution(int w, int h) {
        DEVMODE dm = new DEVMODE();
        dm.dmDeviceName = new string(' ', 32); dm.dmFormName = new string(' ', 32);
        dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        if (EnumDisplaySettings(null, -1, ref dm) == 0) return -999;   // ENUM_CURRENT_SETTINGS
        dm.dmPelsWidth = (uint)w; dm.dmPelsHeight = (uint)h;
        dm.dmFields = 0x80000 | 0x100000;                              // DM_PELSWIDTH | DM_PELSHEIGHT
        return ChangeDisplaySettings(ref dm, 0);
    }

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
    // (continued from the comment above the helpers) Used when Process.MainWindowHandle is still 0 (common right
    // after launch, and for some toolkits' window types). Picks the biggest non-tool-window; only if EVERY
    // candidate is a tool window does it fall back to the biggest tool window, so a borderless/splash-style main
    // window is never silently dropped.
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr h, int idx);
    public static IntPtr FindMainWindow(uint pid) {
        IntPtr best = IntPtr.Zero;     int bestArea = -1;     // best non-tool-window
        IntPtr bestTool = IntPtr.Zero; int bestToolArea = -1; // fallback: best tool window
        EnumWindows((h, lp) => {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == pid && IsWindowVisible(h)) {
                RECT r;
                if (GetWindowRect(h, out r)) {
                    int a = (r.Right - r.Left) * (r.Bottom - r.Top);
                    bool tool = (GetWindowLong(h, -20) & 0x80) != 0;   // GWL_EXSTYLE & WS_EX_TOOLWINDOW
                    if (tool) { if (a > bestToolArea) { bestToolArea = a; bestTool = h; } }
                    else      { if (a > bestArea)     { bestArea = a;     best = h; } }
                }
            }
            return true;
        }, IntPtr.Zero);
        return best != IntPtr.Zero ? best : bestTool;
    }

    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);
    [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr h);
    // Force the window (and all children, plus the nonclient title bar) to paint NOW, then flush the DWM
    // compositor, so a freshly shown window has real, committed content for PrintWindow to grab instead of an
    // unpainted/blank first frame. Flags: RDW_INVALIDATE(0x1)|RDW_ERASE(0x4)|RDW_ALLCHILDREN(0x80)|
    // RDW_UPDATENOW(0x100)|RDW_FRAME(0x400). RDW_FRAME repaints the nonclient area so the window's own title bar
    // is captured (the requirement asks for the WHOLE window). DwmFlush waits for the next composition pass so a
    // DirectComposition/WinUI surface is committed before we PrintWindow it. Return BOOLs ignored (best-effort).
    public static void ForcePaint(IntPtr h) {
        RedrawWindow(h, IntPtr.Zero, IntPtr.Zero, 0x0001 | 0x0004 | 0x0080 | 0x0100 | 0x0400);
        UpdateWindow(h);
        try { DwmFlush(); } catch {}
    }

    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    // Make THIS (capture) process DPI-aware BEFORE any GetWindowRect/PrintWindow. On a >100% DPI display a
    // non-aware process sees GetWindowRect return scaled-down logical sizes, so the PrintWindow bitmap is too
    // small and the window comes out cropped/scaled. Per-Monitor-V2 = (DPI_AWARENESS_CONTEXT)-4 (Win10 1703+);
    // fall back to per-monitor (-3) then system-DPI-aware. Best-effort: returns the level achieved.
    public static string MakeDpiAware() {
        try { if (SetProcessDpiAwarenessContext((IntPtr)(-4))) return "per-monitor-v2"; } catch {}
        try { if (SetProcessDpiAwarenessContext((IntPtr)(-3))) return "per-monitor"; } catch {}
        try { if (SetProcessDPIAware()) return "system"; } catch {}
        return "unchanged";
    }
}
"@

# Make the capture process DPI-aware as the VERY FIRST [HopWin] call — before anything (esp. WinForms
# SystemInformation.WorkingArea, queried later by the gated fallback) locks in this process's DPI context.
# On a >100% DPI display a non-aware process sees GetWindowRect return scaled-down logical sizes, so the
# PrintWindow bitmap is too small and the window comes out cropped/scaled. PrintWindow is position-independent,
# so this is correctness insurance, not the sole cropping cure. If it reports "unchanged" (awareness was already
# locked by the pwsh host), warn loudly so a silent mis-size is visible in CI.
$dpi = [HopWin]::MakeDpiAware()
Write-Host "Capture DPI awareness -> $dpi"
if ($dpi -eq "unchanged") { Write-Host "##[warning] DPI awareness unchanged; GetWindowRect may be scaled on a >100% DPI runner" }

# Blank-detection threshold: how many DISTINCT colors the content area must show to count as "really painted".
# The goal is only to reject an UNRENDERED frame (1 flat color), NOT to grade page richness — so keep this
# conservative. Note this samples a coarse content-only grid (below), which is far fewer points than the .sh
# imgstat path (which samples ~200k pixels over the whole image), so the SAME number means a much harder bar
# here; a sparse-but-real page (a mostly-white Form, a single Toggle) can legitimately have few distinct colors.
# Default 16 robustly separates "unpainted" from "real page" without false-rejecting low-color pages. Override
# with MIN_COLORS (the .sh counterpart reads the same env, where its denser sampling makes a higher value safe).
$MinColors = 16
if ($env:MIN_COLORS -and [int]::TryParse($env:MIN_COLORS, [ref]$null)) { $MinColors = [int]$env:MIN_COLORS }

# Is a captured bitmap effectively blank? Sample a grid and count distinct colors: an unrendered window is a
# single flat color (1), while any real page (the sidebar tree alone has dozens) passes the threshold. Cheap
# (early-exits) and far more reliable than a fixed sleep for "did it draw yet".
function Test-Blank($bmp) {
    # Sample the CONTENT area only — skip the top ~12% (title bar / window chrome) and a thin border — so a
    # window that drew only its frame counts as blank too. A real page (sidebar + content) has many colors
    # here; an unrendered/empty window has ~1.
    $seen = @{}
    $x0 = [int]($bmp.Width * 0.02); $y0 = [int]($bmp.Height * 0.12)
    $x1 = $bmp.Width - $x0;         $y1 = $bmp.Height - [int]($bmp.Height * 0.02)
    if ($x1 -le $x0 -or $y1 -le $y0) { return $true }
    $sx = [Math]::Max(1, [int](($x1 - $x0) / 40))   # finer 40x40 grid -> enough samples to find real variety
    $sy = [Math]::Max(1, [int](($y1 - $y0) / 40))
    for ($y = $y0; $y -lt $y1; $y += $sy) {
        for ($x = $x0; $x -lt $x1; $x += $sx) {
            $c = $bmp.GetPixel($x, $y)
            $seen[($c.R -shl 16) -bor ($c.G -shl 8) -bor $c.B] = $true
            if ($seen.Count -ge $MinColors) { return $false }   # enough variety -> real content
        }
    }
    return $true   # < $MinColors distinct content colors -> effectively blank (or chrome-only)
}

# Capture the WINDOW ITSELF — never the desktop. PrintWindow renders the window's OWN surface into a bitmap sized
# to the window, completely independent of its screen position, z-order, or whether other windows (or the desktop)
# are in front of it. So the result is ALWAYS exactly that window, in its entirety, with nothing else in frame —
# even if it is off-screen, larger than the screen, or occluded. PW_RENDERFULLCONTENT (flag 2) is required to
# capture DirectComposition/WinUI (and Qt) content. There is NO screen-capture path anywhere in this script, so a
# screenshot can never contain the desktop or another window.
function Grab-PrintWindow([IntPtr]$hWnd) {
    $size = [HopWin]::WindowSize($hWnd); $w = $size[0]; $h = $size[1]
    # Dimensions sanity gate FIRST, before allocating any GDI object — so an early return can never leak a
    # Bitmap/Graphics (GDI+ handle). Reject implausible sizes: a degenerate/zero rect, or anything outside
    # 200x150..6000x4000 (a DPI-mis-sized tiny window, or a maximized desktop-sized grab) is not a real
    # 1280x800-ish demo window and must not be captured as success.
    if ($w -lt 200 -or $h -lt 150 -or $w -gt 6000 -or $h -gt 4000) { return $null }
    # 24bpp RGB (NOT the default 32bpp ARGB): PrintWindow's GDI/DWM copy doesn't write the alpha channel, so a
    # 32bpp bitmap comes out fully transparent and the saved PNG renders blank over the gallery's white tile.
    # KEEP 24bpp — this is load-bearing, do not "simplify" to 32bpp.
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = $null; $ok = $false
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)     # any region PrintWindow leaves untouched stays white, not garbage
        $hdc = $g.GetHdc()
        $ok = [HopWin]::PrintWindow($hWnd, $hdc, 2)  # 2 = PW_RENDERFULLCONTENT (DirectComposition/WinUI/Qt)
        $g.ReleaseHdc($hdc)
    } finally {
        if ($g) { $g.Dispose() }                    # always disposed, even if PrintWindow throws
    }
    if (-not $ok) { $bmp.Dispose(); return $null }
    return $bmp
}

# Capture a launched app's main window via PrintWindow ONLY. PrintWindow grabs the window's OWN pixels independent
# of position/z-order/occlusion, so the shot is always exactly that window, in its entirety, with nothing else in
# frame — even off-screen, larger than the screen, or occluded. We NEVER screen-capture, so the result can never
# contain the desktop or another window. Returns $true if a non-blank window was saved, else $false (no file).
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

    # Un-minimize, then a one-time SW_SHOW nudge: some toolkits (Qt's compositor, WinUI/DirectComposition) defer
    # their first paint until shown. This only affects WHEN the window paints, not WHAT PrintWindow grabs (it reads
    # the window's own surface), so it cannot reintroduce desktop/occlusion leakage.
    if ([HopWin]::IsIconic($hWnd)) { [void][HopWin]::ShowWindow($hWnd, 9) }   # SW_RESTORE
    [void][HopWin]::ShowWindow($hWnd, 5)                                       # SW_SHOW (one-time first-paint nudge)

    for ($a = 0; $a -lt 24; $a++) {                 # up to ~14s for the window to paint its first real frame
        Start-Sleep -Milliseconds 600
        [void][HopWin]::ForcePaint($hWnd)           # invalidate+update+DwmFlush so the composited frame is committed
        $bmp = Grab-PrintWindow $hWnd
        if ($null -eq $bmp) { continue }
        if (-not (Test-Blank $bmp)) {
            $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); return $true
        }
        $bmp.Dispose()
    }
    return $false                                    # never painted real content -> no file (better than a blank/desktop)
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

# Human-readable byte size for the summary table.
function Human-Size($b) {
    if ($b -ge 1MB) { "{0:N1} MB" -f ($b / 1MB) }
    elseif ($b -ge 1KB) { "{0:N1} KB" -f ($b / 1KB) }
    else { "$b B" }
}
# "<w>×<h>" for a saved PNG (read + released so it doesn't lock the file), or "—" if unreadable.
function Png-Dims($path) {
    if (-not (Test-Path $path)) { return "—" }
    try {
        $img = [System.Drawing.Image]::FromFile($path)
        $d = "$($img.Width)×$($img.Height)"; $img.Dispose(); return $d
    } catch { return "—" }
}

$ok = 0; $bad = 0
$summaryRows = @()   # one markdown row per attempted screenshot
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
        $status = "fail"
        try {
            $proc = Start-Process -FilePath $exePath -PassThru -ErrorAction Stop
            if (Capture-Window $proc $out) { $status = "ok" }
        } catch {
            Write-Host "  EXC $tk / $pg : $_"
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
        $dims = Png-Dims $out
        $size = if (Test-Path $out) { Human-Size ((Get-Item $out).Length) } else { "—" }
        if ($status -eq "ok") {
            Write-Host "  OK $tk / $pg  ($dims, $size)"; $ok++
            $summaryRows += "| ``$tk`` | ``$pg`` | ✅ ok | $dims | $size |"
        } else {
            Write-Host "  FAIL (no non-blank window) $tk / $pg"; $bad++
            $summaryRows += "| ``$tk`` | ``$pg`` | ❌ blank | $dims | $size |"
        }
    }
}

# Per-screenshot summary -> stdout + $GITHUB_STEP_SUMMARY (so every shot's status is visible in the CI run).
$summary = @()
$summary += "### Screenshots — $($Toolkits -join ', ') (Windows)"
$summary += ""
$summary += "✅ **$ok** captured · ❌ **$bad** failed · $($pgs.Count) playground(s) × $($Toolkits.Count) toolkit(s)"
$summary += ""
$summary += "| Toolkit | Playground | Status | Dimensions | Size |"
$summary += "| --- | --- | --- | --- | ---: |"
$summary += $summaryRows
$summaryText = $summary -join "`n"
Write-Host $summaryText
# UTF-8 so the table's em-dash / ✅ ❌ / × render correctly in the GitHub step summary.
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $summaryText -Encoding utf8 }

Write-Host "Captured $ok screenshot(s) ($bad failed) -> $OutDir"
Get-ChildItem $OutDir -ErrorAction SilentlyContinue | Format-Table Name, Length
exit 0
