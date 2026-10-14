# ==============================================================================
# AeroVPN - Windows Authenticode & Code Signing Tool
# ==============================================================================
param (
    [string]$CertPath = "",
    [string]$CertPassword = "",
    [switch]$UseSelfSignedTestCert
)

$rootDir = "C:\VPN"
$daemonDir = "$rootDir\core\daemon"
$distDir = "$rootDir\dist"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " AeroVPN Windows Binary & Setup Code Signing Utility" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# Locate signtool.exe from Windows SDK
$signtoolPaths = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
if (-not $signtoolPaths) {
    $signtoolPaths = Get-ChildItem "C:\Program Files\Microsoft Visual Studio\*\*\SDK\ScopeCppSDK\vc15\SDK\bin\signtool.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
}

$signtool = $signtoolPaths | Select-Object -First 1

if (-not $signtool) {
    Write-Warning "signtool.exe not found in standard Windows SDK locations."
} else {
    Write-Host "[OK] Located signtool.exe at: $signtool" -ForegroundColor Green
}

# 1. Commercial EV / OV Signing Procedure
if ($CertPath -and (Test-Path $CertPath)) {
    Write-Host "--> Signing binaries using commercial certificate: $CertPath" -ForegroundColor Cyan
    $targets = @(
        "$daemonDir\vpn-daemon.exe",
        "$distDir\AeroVPN_Setup_v1.0.0.exe"
    )

    foreach ($target in $targets) {
        if (Test-Path $target) {
            Write-Host "    Signing $target..."
            & $signtool sign /f $CertPath /p $CertPassword /fd sha256 /tr http://timestamp.digicert.com /td sha256 /d "AeroVPN" /du "https://www.aerovpn.com" $target
        }
    }
    Write-Host "[SUCCESS] Commercial Authenticode digital signature applied!" -ForegroundColor Green
    exit 0
}

# 2. Local Test Signing Guide
Write-Host "`n[COMMERCIAL CODE SIGNING GUIDE]" -ForegroundColor Yellow
Write-Host "To prevent Windows Defender SmartScreen 'Unknown Publisher' warnings in production:" -ForegroundColor White
Write-Host "1. Purchase an EV (Extended Validation) or Standard OV Code Signing Certificate from:" -ForegroundColor White
Write-Host "   - DigiCert (Recommended for instant SmartScreen reputation)" -ForegroundColor Gray
Write-Host "   - Sectigo / Comodo" -ForegroundColor Gray
Write-Host "   - GlobalSign" -ForegroundColor Gray
Write-Host "2. Once your USB Token or PFX file is ready, run:" -ForegroundColor White
Write-Host "   .\installer\sign_windows_binaries.ps1 -CertPath 'C:\path\to\cert.pfx' -CertPassword 'YourPassword'" -ForegroundColor Green
Write-Host "3. Alternatively, for cloud HSM signing (Azure Key Vault / DigiCert ONE):" -ForegroundColor White
Write-Host "   signtool sign /sha1 <Thumbprint> /tr http://timestamp.digicert.com /td sha256 <Binary.exe>" -ForegroundColor Gray
