<#
.SYNOPSIS
  Sign a hoppack-produced MSIX with a throwaway self-signed certificate, install it, and verify the app
  launches — the Windows half of the CI install smoke test. Exits nonzero (failing the job) on any failure.
.PARAMETER Msix         Path to the .msix produced by `hoppack package`.
.PARAMETER Publisher    Subject of the signing cert; MUST equal the package's Publisher (e.g. "CN=Hop").
.PARAMETER IdentityName Package Identity Name from the manifest (e.g. com.hoptools.hopdemo.qt).
.PARAMETER Executable   The app's process name without extension (e.g. hop-demo-qt), used to confirm launch.
.PARAMETER AppId        Application Id in the manifest (hoppack uses "App").
#>
param(
  [Parameter(Mandatory=$true)][string]$Msix,
  [Parameter(Mandatory=$true)][string]$Publisher,
  [Parameter(Mandatory=$true)][string]$IdentityName,
  [Parameter(Mandatory=$true)][string]$Executable,
  [string]$AppId = "App"
)
$ErrorActionPreference = "Stop"
function Fail($m) { Write-Host "::error::$m"; exit 1 }

if (-not (Test-Path $Msix)) { Fail "MSIX not found: $Msix" }

# 1. Locate signtool from the installed Windows SDK.
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { Fail "signtool.exe not found (Windows SDK missing)." }
Write-Host "signtool: $($signtool.FullName)"

# 2. Create a self-signed code-signing cert whose subject matches the package Publisher.
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
& $signtool.FullName sign /fd SHA256 /sha1 $cert.Thumbprint $Msix
if ($LASTEXITCODE -ne 0) { Fail "signtool failed to sign $Msix" }

# 5. Install it.
Write-Host "Installing $Msix"
Add-AppxPackage -Path $Msix
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
