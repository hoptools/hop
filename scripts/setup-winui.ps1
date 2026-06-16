<#
.SYNOPSIS
  Stage everything the CWinUI (WinUI 3 / C++/WinRT) backend needs into `.winui/`, mirroring how
  `setup-windows.ps1` stages GTK4 into `.winlibs/`.

.DESCRIPTION
  WinUI 3 has no C ABI, so HopWinUI talks to it through a hand-written C++/WinRT shim (`Sources/CWinUI`)
  that exposes a pure-C surface. Building that shim needs the WinUI C++/WinRT *projection headers*, which
  Microsoft does not ship pre-generated — so this script:
    1. NuGet-restores the Windows App SDK + WebView2 packages (for their WinMD metadata, import libs,
       and the Windows App Runtime bootstrap).
    2. Runs the Windows SDK's `cppwinrt.exe` to generate the `winrt/Microsoft.UI.Xaml.*.h` headers.
    3. Stages the headers, import libs, and bootstrap DLL into `.winui/`, and writes `.winui/cflags`
       and `.winui/libs` (one flag per line) that `Package.swift` feeds to the CWinUI target.

  Run once before `HOP_TOOLKIT=winui swift build`. Re-run after changing the SDK / App SDK versions.

.PARAMETER Arch
  Target architecture: arm64 (default on ARM64 hosts) or x64. Picks the matching import libs + bootstrap DLL.
#>
[CmdletBinding()]
param(
    [ValidateSet("arm64", "x64")]
    [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }),
    [string]$AppSdkVersion = "1.6.250108002",
    [string]$WebView2Version = "1.0.2210.55"
)
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$winui = Join-Path $repo ".winui"
New-Item -ItemType Directory -Force -Path $winui | Out-Null

# --- Locate the Windows SDK (latest installed) + its cppwinrt.exe and cppwinrt include dir ---
$kits = "C:\Program Files (x86)\Windows Kits\10"
$sdkVersion = Get-ChildItem "$kits\Include" -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "cppwinrt\winrt\base.h") } |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
if (-not $sdkVersion) { throw "No Windows SDK with cppwinrt found under $kits\Include" }
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$cppwinrt = "$kits\bin\$sdkVersion\$hostArch\cppwinrt.exe"
$sdkCppwinrtInc = "$kits\Include\$sdkVersion\cppwinrt"
$sdkUmLib = "$kits\Lib\$sdkVersion\um\$Arch"
Write-Host "Windows SDK $sdkVersion ($hostArch host, $Arch target)"

# --- NuGet-restore the Windows App SDK + WebView2 (metadata + import libs + bootstrap) ---
$nuget = Join-Path $winui "nuget.exe"
if (-not (Test-Path $nuget)) {
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nuget
}
$packages = Join-Path $winui "packages"
& $nuget install Microsoft.WindowsAppSDK -Version $AppSdkVersion -OutputDirectory $packages -Source "https://api.nuget.org/v3/index.json" | Out-Null
& $nuget install Microsoft.Web.WebView2 -Version $WebView2Version -OutputDirectory $packages -Source "https://api.nuget.org/v3/index.json" | Out-Null
$appSdk = Join-Path $packages "Microsoft.WindowsAppSDK.$AppSdkVersion"
$wv2 = Join-Path $packages "Microsoft.Web.WebView2.$WebView2Version\lib\Microsoft.Web.WebView2.Core.winmd"

# --- Generate the WinUI C++/WinRT projection headers from the App SDK WinMDs ---
# Microsoft.UI.Xaml references types spread across several WinMDs (UI / Foundation / Graphics live in the
# uap10.0.18362 set) plus WebView2; reference the system SDK for the Windows.* base projection.
$gen = Join-Path $winui "gen"
$cppArgs = @(
    "-input", (Join-Path $appSdk "lib\uap10.0"),
    "-input", (Join-Path $appSdk "lib\uap10.0.18362\Microsoft.UI.winmd"),
    "-input", (Join-Path $appSdk "lib\uap10.0.18362\Microsoft.Foundation.winmd"),
    "-input", (Join-Path $appSdk "lib\uap10.0.18362\Microsoft.Graphics.winmd"),
    "-input", $wv2,
    "-ref", $sdkVersion,
    "-output", $gen
)
& $cppwinrt @cppArgs
if ($LASTEXITCODE -ne 0) { throw "cppwinrt failed ($LASTEXITCODE)" }

# --- Stage headers, import libs, and bootstrap DLL ---
$stageInc = Join-Path $winui "include"
if (Test-Path $stageInc) { Remove-Item -Recurse -Force $stageInc }
Copy-Item -Recurse -Force (Join-Path $appSdk "include") $stageInc   # MddBootstrap.h, WindowsAppSDK-VersionInfo.h, ...
$stageLib = Join-Path $winui "lib\$Arch"
New-Item -ItemType Directory -Force -Path $stageLib | Out-Null
Copy-Item -Force (Join-Path $appSdk "lib\win10-$Arch\Microsoft.WindowsAppRuntime.Bootstrap.lib") $stageLib
Copy-Item -Force (Join-Path $appSdk "lib\win10-$Arch\Microsoft.WindowsAppRuntime.lib") $stageLib
Copy-Item -Force (Join-Path $appSdk "runtimes\win-$Arch\native\Microsoft.WindowsAppRuntime.Bootstrap.dll") $winui

# --- Emit cflags / libs (one flag per line so paths with spaces stay intact; forward slashes because the
#     Swift toolchain's clang doesn't accept backslash include/lib paths) ---
@(
    "-I$gen",
    "-I$sdkCppwinrtInc",
    "-I$stageInc"
) | ForEach-Object { $_.Replace('\', '/') } | Set-Content -Path (Join-Path $winui "cflags") -Encoding ascii
@(
    "-L$stageLib",
    "-L$sdkUmLib",
    "-lMicrosoft.WindowsAppRuntime.Bootstrap",
    "-lWindowsApp"
) | ForEach-Object { $_.Replace('\', '/') } | Set-Content -Path (Join-Path $winui "libs") -Encoding ascii

Write-Host "CWinUI staged into $winui (arch=$Arch). cflags/libs written; bootstrap DLL copied." -ForegroundColor Green
