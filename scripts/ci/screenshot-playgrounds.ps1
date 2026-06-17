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

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Capture-Screen($path) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

$ok = 0; $bad = 0
foreach ($tk in $Toolkits) {
    $exe = Exec-For $tk
    if (-not $exe) { Write-Host "unknown toolkit: $tk"; continue }
    $exePath = Join-Path $bin "$exe.exe"
    if (-not (Test-Path $exePath)) { Write-Host "skip ${tk}: $exePath not built"; continue }
    foreach ($pg in $pgs) {
        $env:HOP_PLAYGROUND_ID = $pg
        $out = Join-Path $OutDir "$($tk)__$($pg).png"
        $proc = $null
        try {
            $proc = Start-Process -FilePath $exePath -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 4
            Capture-Screen $out
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
