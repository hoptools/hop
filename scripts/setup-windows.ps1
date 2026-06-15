<#
.SYNOPSIS
    Prepare a Windows machine to build HopUI's GTK4 backend with the MSVC Swift toolchain.

.DESCRIPTION
    GTK4 on Windows is provided by MSYS2 (the CLANGARM64 environment on Windows-on-ARM, or MINGW64 /
    CLANG64 on x64). Two mismatches with the MSVC-based Swift toolchain need bridging, and this script
    handles both by populating the repo-local `.winlibs/` directory (read by Package.swift on Windows):

      1. SwiftPM's built-in pkg-config parser trips over MSYS2's harfbuzz<->freetype2 `.pc` dependency
         cycle and drops GTK's `-I` include flags. We capture the correct flags with pkgconf and write
         them to `.winlibs/gtk4.cflags` and `.winlibs/gtk4.libs`.

      2. The MSVC linker (lld-link) cannot consume MSYS2's GNU-format `.dll.a` import libraries. lld-link
         *can* read their archive contents, but the driver only looks for `<name>.lib`. We copy every
         `lib<name>.dll.a` to `.winlibs/<name>.lib` so `-l<name>` resolves.

    Prerequisites (install once):
      winget install MSYS2.MSYS2
      C:\msys64\usr\bin\pacman.exe -Sy --noconfirm
      C:\msys64\usr\bin\pacman.exe -S --needed --noconfirm `
          mingw-w64-clang-aarch64-gtk4 mingw-w64-clang-aarch64-pkgconf     # ARM64
      # (on x64 Windows use the mingw-w64-x86_64-* or mingw-w64-clang-x86_64-* packages instead)

    After running this script, build with the MSYS2 toolkit on PATH so pkgconf and the GTK runtime
    DLLs are found:
      $env:Path = "$Prefix\bin;" + $env:Path
      swift build
      swift run hop-demo-gtk4

    NOTE: invoke this with PowerShell, e.g. `pwsh -File scripts/setup-windows.ps1` (or a CI step with
    `shell: pwsh`). Running a .ps1 from cmd hands it to the shell file association instead of executing
    it, which on a headless runner can hang with no output.

.PARAMETER Prefix
    The MSYS2 toolchain prefix that contains GTK4. Defaults to the CLANGARM64 prefix on ARM64 and the
    MINGW64 prefix on x64.
#>
[CmdletBinding()]
param(
    [string]$Prefix
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # suppress progress bars that can stall/garble CI output

# Timestamped, immediately-flushed logging so a hang in CI shows exactly which phase we reached. If the
# CI step shows none of these lines at all, the script never started executing (e.g. a .ps1 invoked from
# cmd rather than via `pwsh -File` / `shell: pwsh`) rather than hanging inside the script.
$script:startTime = Get-Date
function Log([string]$message) {
    $elapsed = ((Get-Date) - $script:startTime).TotalSeconds
    Write-Host ("[setup-windows +{0,6:0.0}s] {1}" -f $elapsed, $message)
    [Console]::Out.Flush()
}

# Run a native exe, logging the command before and the captured output after, so a hang is attributed to
# the exact call. stderr is folded into stdout so pkgconf diagnostics are visible.
function Invoke-Logged([string]$exe, [string[]]$arguments) {
    Log "running: `"$exe`" $($arguments -join ' ')"
    $output = (& $exe @arguments 2>&1 | Out-String)
    Log "  -> exit $LASTEXITCODE, output: $($output.Trim())"
    return $output
}

Log "script started (PowerShell $($PSVersionTable.PSVersion), PID $PID)"

# Pick the MSYS2 environment matching the host architecture unless the caller overrides it.
if (-not $Prefix) {
    $arch = (Get-CimInstance Win32_Processor).Architecture   # 12 = ARM64, 9 = x64
    $Prefix = if ($arch -eq 12) { 'C:\msys64\clangarm64' } else { 'C:\msys64\mingw64' }
}
$libDir = Join-Path $Prefix 'lib'
$pkgconf = Join-Path $Prefix 'bin\pkgconf.exe'
Log "Prefix  = $Prefix"
Log "libDir  = $libDir"
Log "pkgconf = $pkgconf"

if (-not (Test-Path $libDir))  { throw "MSYS2 lib dir not found: $libDir. Install GTK4 first (see this script's header)." }
if (-not (Test-Path $pkgconf)) { throw "pkgconf not found: $pkgconf. Install the *-pkgconf package first." }
Log "verified lib dir and pkgconf exist"

$repoRoot = Split-Path -Parent $PSScriptRoot
$winlibs  = Join-Path $repoRoot '.winlibs'
New-Item -ItemType Directory -Force $winlibs | Out-Null
Log "repoRoot = $repoRoot"
Log "winlibs  = $winlibs"

# 1. Generate MSVC-style import libraries: lib<name>.dll.a -> <name>.lib
Log "scanning $libDir for lib*.dll.a import libraries ..."
$dllAs = @(Get-ChildItem (Join-Path $libDir 'lib*.dll.a') -ErrorAction SilentlyContinue)
Log "found $($dllAs.Count) lib*.dll.a files; copying to .winlibs as <name>.lib ..."
$count = 0
foreach ($f in $dllAs) {
    $name = $f.Name -replace '^lib', '' -replace '\.dll\.a$', ''   # libgtk-4.dll.a -> gtk-4
    Copy-Item $f.FullName (Join-Path $winlibs "$name.lib") -Force
    $count++
    if ($count % 25 -eq 0) { Log "  ... copied $count / $($dllAs.Count)" }
}
Log "generated $count import libraries (.lib)."

# 2. Capture the pkg-config flags that SwiftPM's parser would otherwise drop. pkgconf needs the
#    GTK runtime on PATH so it can resolve the .pc files under the prefix.
$env:Path = (Join-Path $Prefix 'bin') + ';' + $env:Path
$env:PKG_CONFIG_PATH = (Join-Path $libDir 'pkgconfig') + ';' + (Join-Path $Prefix 'share\pkgconfig')
Log "PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH"

$version = (Invoke-Logged $pkgconf @('--modversion', 'gtk4')).Trim()
$cflags  = (Invoke-Logged $pkgconf @('--cflags', 'gtk4')) -split '\s+' | Where-Object { $_ -match '^-(I|D)' }
$libs    = (Invoke-Logged $pkgconf @('--libs',   'gtk4')) -split '\s+' | Where-Object { $_ -match '^-l' }
if (-not $cflags) { throw "pkgconf returned no cflags for gtk4 - is mingw-w64-*-gtk4 installed?" }

# Write LF-terminated, BOM-free files (Package.swift reads them as plain UTF-8).
[IO.File]::WriteAllText((Join-Path $winlibs 'gtk4.cflags'), (($cflags -join "`n") + "`n"))
[IO.File]::WriteAllText((Join-Path $winlibs 'gtk4.libs'),   (($libs   -join "`n") + "`n"))
Log "captured $($cflags.Count) cflags and $($libs.Count) link flags for gtk4 $version."
Log "done."
Write-Host ""
Write-Host "Done. Now build with the MSYS2 toolkit on PATH:" -ForegroundColor Green
Write-Host "  `$env:Path = `"$Prefix\bin;`" + `$env:Path"
Write-Host "  swift run hop-demo-gtk4"
