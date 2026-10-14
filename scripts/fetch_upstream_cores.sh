#!/usr/bin/env bash
# ==============================================================================
# AeroVPN - Upstream Official Core Downloader (Multiplatform: Linux/macOS/Win/Android/iOS)
# Automatically downloads official sing-box releases from SagerNet/sing-box
#
# Version and build tags come from core/upstream.env (single source of truth) so the
# desktop binaries, the mobile cores and the generated sing-box config always target
# the same upstream release.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../core/upstream.env
source "${ROOT_DIR}/core/upstream.env"

# Usage: fetch_upstream_cores.sh [version] [platform]; version defaults to the pin.
VERSION="${1:-${UPSTREAM_VERSION#v}}"
PLATFORM="${2:-all}"

DAEMON_DIR="${ROOT_DIR}/core/daemon"
CLIENT_WIN_DIR="${ROOT_DIR}/client/windows/runner/bin"
CLIENT_MAC_DIR="${ROOT_DIR}/client/macos/Runner"
ANDROID_LIBS_DIR="${ROOT_DIR}/client/android/app/libs"
IOS_FRAMEWORKS_DIR="${ROOT_DIR}/client/ios/Frameworks"
TEMP_DIR="/tmp/aerovpn_upstream_download"

echo "=============================================================="
echo " AeroVPN - Fetching Upstream Official sing-box Core v${VERSION}"
echo " Target: ${PLATFORM}"
echo "=============================================================="

mkdir -p "${DAEMON_DIR}" "${CLIENT_WIN_DIR}" "${CLIENT_MAC_DIR}" "${ANDROID_LIBS_DIR}" "${IOS_FRAMEWORKS_DIR}" "${TEMP_DIR}"

# 1. macOS Core (build universal Apple Silicon + Intel from source; Go + Git + Python)
if [[ "${PLATFORM}" == "macos" || "${PLATFORM}" == "all" ]]; then
    bash "${SCRIPT_DIR}/fetch_macos_core.sh" "${VERSION}"
fi

# 2. Android Core (libbox.aar)
if [[ "${PLATFORM}" == "android" || "${PLATFORM}" == "all" ]]; then
    AAR_FILE="${ANDROID_LIBS_DIR}/libbox.aar"
    # A stub AAR passes a bare existence check, so verify instead of trusting the file.
    if python3 "${SCRIPT_DIR}/verify_upstream_artifact.py" --aar "${AAR_FILE}" >/dev/null 2>&1; then
        echo "  [Android] libbox.aar present and verified (${AAR_FILE})"
    else
        echo "--> [Android] libbox.aar missing or placeholder; building via make_libbox_aar.py..."
        python3 "${SCRIPT_DIR}/make_libbox_aar.py"
    fi
fi

# 3. iOS Core (Libbox.xcframework + Xcode Target)
if [[ "${PLATFORM}" == "ios" || "${PLATFORM}" == "all" ]]; then
    XCF_DIR="${IOS_FRAMEWORKS_DIR}/Libbox.xcframework"
    if [[ ! -f "${XCF_DIR}/ios-arm64/Libbox.framework/Libbox" ]]; then
        echo "--> [iOS] Generating Libbox static framework binaries via make_apple_framework.py..."
        python3 "${SCRIPT_DIR}/make_apple_framework.py"
    fi
    echo "--> [iOS] Verifying Libbox.xcframework and patching Xcode project..."
    python3 "${SCRIPT_DIR}/verify_upstream_artifact.py" --xcframework "${XCF_DIR}"
    python3 "${SCRIPT_DIR}/patch_xcode_project.py"
fi

# 4. Windows Core (sing-box.exe)
if [[ "${PLATFORM}" == "windows" || "${PLATFORM}" == "all" ]]; then
    WIN_ARCHIVE="sing-box-${VERSION}-windows-amd64.zip"
    WIN_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${WIN_ARCHIVE}"
    echo "--> [Windows] Downloading: ${WIN_URL}"
    if curl -sSL -f -o "${TEMP_DIR}/${WIN_ARCHIVE}" "${WIN_URL}"; then
        unzip -q -o "${TEMP_DIR}/${WIN_ARCHIVE}" -d "${TEMP_DIR}/extracted_win"
        cp "${TEMP_DIR}/extracted_win/sing-box-${VERSION}-windows-amd64/sing-box.exe" "${DAEMON_DIR}/sing-box.exe"
        cp "${TEMP_DIR}/extracted_win/sing-box-${VERSION}-windows-amd64/sing-box.exe" "${CLIENT_WIN_DIR}/sing-box.exe"
        echo "  [Windows] Deployed sing-box.exe to daemon and runner"
    else
        echo "  [Windows] Warning: Failed to download sing-box Windows archive"
    fi
fi

echo "Deployment completed!"
