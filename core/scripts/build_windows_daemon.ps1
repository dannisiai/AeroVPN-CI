# ==============================================================================
# AeroVPN - Windows Helper Daemon & Wintun Builder
# ==============================================================================

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = (Get-Item "$scriptDir\..\..").FullName
$daemonDir = "$rootDir\core\daemon"
# The installer (installer/aerovpn_installer.iss) packs the daemon from
# core\daemon\vpn-daemon.exe, so build straight into that location.
$outputDir = $daemonDir

Write-Host "==> [1/3] Creating output directory: $outputDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Host "==> [2/3] Compiling Windows Privileged Helper Daemon..." -ForegroundColor Cyan
Push-Location $daemonDir
try {
    $env:CGO_ENABLED = "0"
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    # Build the whole package: config_guard.go lives next to main.go and
    # `go build main.go` would not compile it.
    go build -ldflags="-s -w -X main.Version=1.0.0" -o "$outputDir\vpn-daemon.exe" .
    Write-Host "Successfully compiled vpn-daemon.exe" -ForegroundColor Green
}
finally {
    Pop-Location
}

Write-Host "==> [3/3] Build complete: $outputDir\vpn-daemon.exe" -ForegroundColor Green
