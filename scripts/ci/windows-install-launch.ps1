<#
.SYNOPSIS
  Sign a hoppack-produced MSIX with a throwaway self-signed certificate, install it, and verify the app
  launches — the Windows half of the CI install smoke test. Exits nonzero (failing the job) on any failure.

  Identity (Publisher, package Name), the Application Id, and the executable name are read straight from the
  package's AppxManifest.xml, so the signing-cert subject always matches the package Publisher (signtool
  errors 0x8007000b otherwise) and CI never has to track values that live in hoppack.yaml. The parameters
  below are optional overrides.
.PARAMETER Msix         Path to the .msix produced by `hoppack package`.
.PARAMETER Publisher    Override the signing-cert subject (default: the manifest's Identity Publisher).
.PARAMETER IdentityName Override the package Identity Name (default: read from the manifest).
.PARAMETER Executable   Override the process name to confirm launch (default: the manifest's app executable).
.PARAMETER AppId        Override the Application Id (default: read from the manifest; hoppack uses "App").
#>
param(
  [Parameter(Mandatory=$true)][string]$Msix,
  [string]$Publisher,
  [string]$IdentityName,
  [string]$Executable,
  [string]$AppId
)
$ErrorActionPreference = "Stop"
function Fail($m) { Write-Host "::error::$m"; exit 1 }

if (-not (Test-Path $Msix)) { Fail "MSIX not found: $Msix" }
$MsixPath = (Resolve-Path $Msix).Path

# Read identity + application info from the package manifest so nothing is hardcoded against hoppack.yaml.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($MsixPath)
try {
  $entry = $zip.Entries | Where-Object { $_.FullName -eq "AppxManifest.xml" } | Select-Object -First 1
  if (-not $entry) { Fail "AppxManifest.xml not found in $Msix" }
  $sr = New-Object System.IO.StreamReader($entry.Open())
  [xml]$manifest = $sr.ReadToEnd()
  $sr.Close()
} finally { $zip.Dispose() }

$app = $manifest.Package.Applications.Application
if ($app -is [array]) { $app = $app[0] }
if (-not $Publisher)    { $Publisher    = $manifest.Package.Identity.Publisher }
if (-not $IdentityName) { $IdentityName = $manifest.Package.Identity.Name }
if (-not $AppId)        { $AppId        = $app.Id }
if (-not $Executable)   { $Executable   = [System.IO.Path]::GetFileNameWithoutExtension([string]$app.Executable) }
Write-Host "Manifest: Publisher=$Publisher Name=$IdentityName App=$AppId Exe=$Executable"

# 1. Locate signtool from the installed Windows SDK.
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { Fail "signtool.exe not found (Windows SDK missing)." }
Write-Host "signtool: $($signtool.FullName)"

# 2. Create a self-signed code-signing cert whose subject matches the package Publisher exactly.
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Publisher `
          -CertStoreLocation "Cert:\CurrentUser\My" -KeyUsage DigitalSignature `
          -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")
Write-Host "Created cert $($cert.Thumbprint) for $Publisher"

# 3. Trust the cert (so the signed MSIX installs): export it and import into LocalMachine TrustedPeople + Root.
$cer = Join-Path $env:RUNNER_TEMP "hoppack-signing.cer"
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null

# 4. Sign the MSIX (no timestamp: this is a throwaway dev cert).
& $signtool.FullName sign /fd SHA256 /sha1 $cert.Thumbprint $MsixPath
if ($LASTEXITCODE -ne 0) { Fail "signtool failed to sign $Msix" }

# 5. Install it.
Write-Host "Installing $Msix"
Add-AppxPackage -Path $MsixPath
$pkg = Get-AppxPackage -Name $IdentityName
if (-not $pkg) { Fail "package $IdentityName did not register after install" }
Write-Host "Installed $($pkg.PackageFullName)"

# 6. Launch via the AppsFolder URI and confirm the process comes up.
Write-Host "Launching $($pkg.PackageFamilyName)!$AppId"
Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!$AppId"

$launched = $false
foreach ($_ in 1..30) {
  if (Get-Process -Name $Executable -ErrorAction SilentlyContinue) { $launched = $true; break }
  Start-Sleep -Milliseconds 500
}

# Clean up regardless of result.
Stop-Process -Name $Executable -Force -ErrorAction SilentlyContinue
Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue

if (-not $launched) { Fail "$Executable did not launch from the installed MSIX" }
Write-Host "OK: Windows install + launch succeeded for $IdentityName"
