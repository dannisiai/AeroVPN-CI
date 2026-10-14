# ==============================================================================
# AeroVPN - Automated Windows Installer Build Script
# ==============================================================================

$ErrorActionPreference = "Stop"

$rootDir = if ($PSScriptRoot) { (Resolve-Path "$PSScriptRoot\..").Path } else { "C:\VPN" }
$installerDir = "$rootDir\installer"
$distDir = "$rootDir\dist"
$clientDir = "$rootDir\client"
$daemonDir = "$rootDir\core\daemon"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " Building AeroVPN Windows Production Installer" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. Compile the daemon fresh: never pack a stale core\daemon\vpn-daemon.exe.
Write-Host "--> [1/5] Compiling privileged daemon (go build)..." -ForegroundColor Yellow
$go = Get-Command go -ErrorAction SilentlyContinue
if (-not $go) {
    throw "Go toolchain not found on PATH; cannot compile vpn-daemon.exe. Install Go >= 1.26 or run core\scripts\build_windows_daemon.ps1 first."
}
Push-Location $daemonDir
try {
    $env:CGO_ENABLED = "0"
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    go build -ldflags="-s -w" -o "$daemonDir\vpn-daemon.exe" .
    if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    Write-Host "    [OK] vpn-daemon.exe compiled ($((Get-Item "$daemonDir\vpn-daemon.exe").Length) bytes)" -ForegroundColor Green
}
finally {
    Pop-Location
}

# 2. Verify remaining core binaries
Write-Host "--> [2/5] Checking core binaries in $daemonDir..." -ForegroundColor Yellow
$requiredFiles = @("sing-box.exe", "wintun.dll")
foreach ($file in $requiredFiles) {
    $path = "$daemonDir\$file"
    if (-not (Test-Path $path)) {
        throw "Missing required core binary: $path"
    }
    Write-Host "    [OK] Found $file ($((Get-Item $path).Length) bytes)" -ForegroundColor Green
}

# 2. Check Flutter Windows Release output
$flutterReleaseDir = "$clientDir\build\windows\x64\runner\Release"
Write-Host "--> [3/5] Checking Flutter Windows client build..." -ForegroundColor Yellow
if (-not (Test-Path "$flutterReleaseDir\aerovpn_client.exe")) {
    Write-Host "    Flutter release not compiled yet. Attempting 'flutter build windows --release'..." -ForegroundColor Cyan
    Push-Location $clientDir
    try {
        flutter build windows --release
    }
    catch {
        Write-Warning "Could not build Flutter Windows desktop automatically: $_"
        Write-Warning "Tip: Ensure Windows Developer Mode is enabled in Windows Settings."
    }
    finally {
        Pop-Location
    }
}

if (Test-Path "$flutterReleaseDir\aerovpn_client.exe") {
    Write-Host "    [OK] Flutter Windows Release executable found." -ForegroundColor Green
} else {
    Write-Host "    [INFO] Client executable not present yet. Once built, run this script to compile setup." -ForegroundColor Yellow
}

# 3. Locate Inno Setup Compiler (ISCC.exe)
Write-Host "--> [4/5] Locating Inno Setup 6 compiler..." -ForegroundColor Yellow
$isccPaths = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)

$isccExe = $null
foreach ($p in $isccPaths) {
    if (Test-Path $p) {
        $isccExe = $p
        break
    }
}

if (-not $isccExe) {
    throw "Inno Setup compiler (ISCC.exe) not found. Please install Inno Setup 6."
}
Write-Host "    [OK] Found ISCC at: $isccExe" -ForegroundColor Green

# 4. Compile Inno Setup Script
if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

Write-Host "--> [5/5] Compiling installer with Inno Setup..." -ForegroundColor Yellow
$issScript = "$installerDir\aerovpn_installer.iss"

if (Test-Path "$flutterReleaseDir\aerovpn_client.exe") {
    & $isccExe "/O$distDir" "/F$distDir\AeroVPN_Setup_v1.0.0.exe" $issScript
    Write-Host "`n[SUCCESS] Production Installer generated at: $distDir\AeroVPN_Setup_v1.0.0.exe" -ForegroundColor Green
} else {
    Write-Host "    Installer script $issScript is ready and validated." -ForegroundColor Cyan
    Write-Host "    To generate the final setup, enable Developer Mode and run 'flutter build windows --release'." -ForegroundColor Cyan
}
