# ==============================================================================
# AeroVPN - Android Production Keystore Generator
#
# The signing password is a SECRET: it is read from the KEYSTORE_PASSWORD
# environment variable, or interactively prompted for when unset.
# Never hardcode it in source control.
# ==============================================================================
param(
    [string]$KeystorePath = "C:\VPN\client\android\app\aerovpn-release-key.jks",
    [string]$PropsPath = "C:\VPN\client\android\key.properties"
)

Write-Host "==> Generating Production RSA 4096-bit Android Keystore..." -ForegroundColor Cyan

if (-not $env:KEYSTORE_PASSWORD -or [string]::IsNullOrWhiteSpace($env:KEYSTORE_PASSWORD)) {
    $secure = Read-Host "Enter keystore password" -AsSecureString
    $env:KEYSTORE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
$pass = $env:KEYSTORE_PASSWORD
if ([string]::IsNullOrWhiteSpace($pass)) {
    Write-Error "KEYSTORE_PASSWORD is empty; aborting."
    exit 1
}

if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
    Write-Warning "keytool not found on PATH. Please ensure JDK/Java is installed to generate .jks."
    Write-Host "Command to run once JDK is available:"
    Write-Host "keytool -genkey -v -keystore `"$KeystorePath`" -alias aerovpn-release -keyalg RSA -keysize 4096 -validity 10000 (passwords supplied via KEYSTORE_PASSWORD)" -ForegroundColor Yellow
    exit 1
}

keytool -genkey -v -keystore $KeystorePath `
    -alias aerovpn-release `
    -keyalg RSA `
    -keysize 4096 `
    -validity 10000 `
    -dname "CN=AeroVPN, OU=Security, O=Aero Technologies Inc., L=Singapore, C=SG" `
    -storepass "$pass" `
    -keypass "$pass"

Set-Content -Path $PropsPath -Value @"
storePassword=$pass
keyPassword=$pass
keyAlias=aerovpn-release
storeFile=app/$(Split-Path -Leaf $KeystorePath)
"@

Write-Host "[SUCCESS] Generated: $KeystorePath and configured $PropsPath" -ForegroundColor Green
