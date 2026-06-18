# Build the `hoppack` packaging tool (its own package at Tools/HopPackaging) and run it against the Showcase
# demo package to produce an installer. hoppack uses its current directory as the package dir (and builds the
# demo executable there), so we build the tool from Tools/HopPackaging and invoke it with the Showcase
# package as the working directory.
#
#   ./scripts/ci/package.ps1 -Target <target> -Output <output-path>
param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = "Stop"

$root = (Resolve-Path "$PSScriptRoot/../..").Path
Set-Location $root

$tool = Join-Path $root "Tools/HopPackaging"
swift build --package-path $tool --product hoppack
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$bin = (swift build --package-path $tool --product hoppack --show-bin-path).Trim()
$hoppack = Join-Path $bin "hoppack.exe"

$outDir = Split-Path -Parent $Output
if ($outDir) { New-Item -ItemType Directory -Force $outDir | Out-Null }
$outAbs = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path (Get-Location).Path $Output }

Set-Location (Join-Path $root "Demos/Apps/Showcase")
& $hoppack package --target $Target --output $outAbs
exit $LASTEXITCODE
