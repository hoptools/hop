<#
.SYNOPSIS
  Build and run the HopUI WinUI 3 demo on Windows.

.DESCRIPTION
  One-shot "build & run" for the WinUI backend, the Windows counterpart of scripts/run-gtk4.sh etc. It:
    1. Stages the WinUI C++/WinRT dependencies into `.winui/` (via setup-winui.ps1) if not already present.
    2. Builds the WinUI toolkit + demo (`HOP_TOOLKIT=winui swift build`).
    3. Copies the Windows App Runtime bootstrap DLL beside the executable (the CWinUI shim imports it, so it
       must be on the DLL search path at load time) and puts the Swift runtime DLLs on PATH.
    4. Launches hop-demo-winui (blocks until the window is closed).

  Requires: a Windows SDK with cppwinrt (for setup-winui.ps1) and a matching Windows App Runtime installed
  to run, e.g. `winget install --id Microsoft.WindowsAppRuntime.1.6 --force`.

.PARAMETER Playground
  Optional playground id to open directly (e.g. slider, datePicker, colorPicker, files) — sets HOP_PLAYGROUND_ID.
#>
[CmdletBinding()]
param([string]$Playground)
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
$env:HOP_TOOLKIT = "winui"

# 1. Stage .winui (cppwinrt-generated headers + import libs + bootstrap) the first time.
if (-not (Test-Path (Join-Path $repo ".winui\cflags"))) {
    Write-Host "Staging WinUI dependencies into .winui ..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "setup-winui.ps1")
}

# 2. Build the WinUI toolkit + demo.
Write-Host "Building hop-demo-winui ..." -ForegroundColor Cyan
swift build --product hop-demo-winui
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }

# 3. Locate the build output + executable.
$binPath = (swift build --product hop-demo-winui --show-bin-path).Trim()
$exe = Join-Path $binPath "hop-demo-winui.exe"
if (-not (Test-Path $exe)) { throw "demo executable not found at $exe" }

# 4. The bootstrap DLL is a load-time import of the shim, so it must sit beside the exe.
Copy-Item (Join-Path $repo ".winui\Microsoft.WindowsAppRuntime.Bootstrap.dll") $binPath -Force

# 5. Put the Swift runtime DLLs (swiftCore.dll, Foundation.dll, …) on PATH.
$swiftHome = Split-Path (Get-Command swift).Source
while ($swiftHome -and -not (Test-Path (Join-Path $swiftHome "Runtimes"))) { $swiftHome = Split-Path $swiftHome }
if ($swiftHome) {
    $runtimeBin = Get-ChildItem (Join-Path $swiftHome "Runtimes") -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "usr\bin" } |
        Where-Object { Test-Path (Join-Path $_ "swiftCore.dll") } | Select-Object -First 1
    if ($runtimeBin) { $env:PATH = "$runtimeBin;$env:PATH" }
}

# 6. Run (blocks until the demo window closes).
if ($Playground) { $env:HOP_PLAYGROUND_ID = $Playground }
Write-Host "Launching hop-demo-winui ..." -ForegroundColor Green
& $exe
