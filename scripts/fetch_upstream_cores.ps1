# ==============================================================================
# AeroVPN - Upstream Official Core Downloader (Multiplatform: Win/Mac/Android/iOS)
# Automatically downloads official sing-box releases from SagerNet/sing-box
# ==============================================================================

[CmdletBinding()]
param(
    # Default comes from core/upstream.env (single source of truth) further below.
    [string]$Version = "",
    [string]$Platform = "windows", # "windows", "macos", "android", "ios", "all"
    [string]$Arch = "amd64"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = (Get-Item "$scriptDir\..").FullName

# Keep desktop binaries, mobile cores and the generated config on the same upstream
# release: read the pin from core/upstream.env.
$upstreamEnvPath = "$rootDir\core\upstream.env"
if (Test-Path $upstreamEnvPath) {
    $pinnedVersion = (Select-String -Path $upstreamEnvPath -Pattern '^UPSTREAM_VERSION="?(.+?)"?$' |
        Select-Object -First 1).Matches.Groups[1].Value
    if (-not $Version -and $pinnedVersion) { $Version = $pinnedVersion.TrimStart("v") }
}
if (-not $Version) { $Version = "1.14.3" }
$daemonDir = "$rootDir\core\daemon"
$clientBinDir = "$rootDir\client\windows\runner\bin"
$macBinDir = "$rootDir\client\macos\Runner"
$androidLibsDir = "$rootDir\client\android\app\libs"
$iosFrameworksDir = "$rootDir\client\ios\Frameworks"
$tempDir = "$env:TEMP\aerovpn_upstream_download"

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " AeroVPN - Fetching Upstream Official sing-box Core v$Version" -ForegroundColor Cyan
Write-Host " Target: $Platform ($Arch)" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $daemonDir | Out-Null
New-Item -ItemType Directory -Force -Path $clientBinDir | Out-Null
New-Item -ItemType Directory -Force -Path $macBinDir | Out-Null
New-Item -ItemType Directory -Force -Path $androidLibsDir | Out-Null
New-Item -ItemType Directory -Force -Path $iosFrameworksDir | Out-Null
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# 1. Windows Core
if ($Platform -eq "windows" -or $Platform -eq "all") {
    $archiveName = "sing-box-$Version-windows-$Arch.zip"
    $downloadUrl = "https://github.com/SagerNet/sing-box/releases/download/v$Version/$archiveName"
    $zipPath = "$tempDir\$archiveName"

    Write-Host "--> [Windows] Downloading: $downloadUrl" -ForegroundColor Yellow
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
        $extractPath = "$tempDir\extracted_win"
        if (Test-Path $extractPath) { Remove-Item -Recurse -Force $extractPath }
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        $extractedExe = Get-ChildItem -Path $extractPath -Recurse -Filter "sing-box.exe" | Select-Object -First 1
        if ($extractedExe) {
            Copy-Item -Path $extractedExe.FullName -Destination "$daemonDir\sing-box.exe" -Force
            Copy-Item -Path $extractedExe.FullName -Destination "$clientBinDir\sing-box.exe" -Force
            Write-Host "  [Windows] Deployed sing-box.exe to daemon and runner" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Failed downloading Windows core: $_"
    }

    $wintunSource = "$daemonDir\wintun.dll"
    if (Test-Path $wintunSource) {
        Copy-Item -Path $wintunSource -Destination "$clientBinDir\wintun.dll" -Force
    }
}

# 2. macOS Core
# Build the pinned source with the pinned Go compiler, CGO disabled, for macOS 13.
# This does not execute the macOS core; it works on Windows and macOS hosts.
if ($Platform -eq "macos" -or $Platform -eq "all") {
    python "$scriptDir\build_macos_core.py" --version $Version
    if ($LASTEXITCODE -ne 0) { throw "macOS universal core preparation failed." }
}

# 3. Android Core (libbox.aar)
if ($Platform -eq "android" -or $Platform -eq "all") {
    $aarPath = "$androidLibsDir\libbox.aar"
    if (-not (Test-Path $aarPath)) {
        Write-Host "--> [Android] Generating libbox.aar via make_libbox_aar.py..." -ForegroundColor Yellow
        python "$scriptDir\make_libbox_aar.py"
    } else {
        Write-Host "  [Android] Verifying existing libbox.aar..." -ForegroundColor Yellow
        python "$scriptDir\verify_upstream_artifact.py" --aar $aarPath
    }
}

# 4. Apple iOS Core (Libbox.xcframework + Xcode Target)
if ($Platform -eq "ios" -or $Platform -eq "all") {
    $xcfPath = "$iosFrameworksDir\Libbox.xcframework"
    $xcfBin = "$xcfPath\ios-arm64\Libbox.framework\Libbox"
    if (-not (Test-Path $xcfBin)) {
        Write-Host "--> [iOS] Generating Libbox static framework binaries via make_apple_framework.py..." -ForegroundColor Yellow
        python "$scriptDir\make_apple_framework.py"
    }
    Write-Host "--> [iOS] Verifying Libbox.xcframework (rejects placeholder stubs)..." -ForegroundColor Yellow
    python "$scriptDir\verify_upstream_artifact.py" --xcframework $xcfPath
    Write-Host "--> [iOS] Applying Xcode project target patch..." -ForegroundColor Yellow
    python "$scriptDir\patch_xcode_project.py"
}

Write-Host "Deployment completed!" -ForegroundColor Green
