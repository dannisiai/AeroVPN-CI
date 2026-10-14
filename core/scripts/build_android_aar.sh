#!/usr/bin/env bash
# ==============================================================================
# AeroVPN - Android libbox.aar Automated Build Script
# Targets: arm64-v8a, armeabi-v7a, x86_64
# Based on upstream official: https://github.com/SagerNet/sing-box/tree/${UPSTREAM_VERSION}/experimental/libbox
#
# Mirrors the upstream build recipe (Makefile: lib_install / lib_android, and
# cmd/internal/build_libbox -target android): upstream gomobile fork, pinned release
# tag, upstream build tags, NDK pin. Version/tags live in core/upstream.env.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../upstream.env
source "${ROOT_DIR}/core/upstream.env"
source "${SCRIPT_DIR}/upstream_build_common.sh"

UPSTREAM_DIR="${ROOT_DIR}/core/upstream/sing-box"
OUTPUT_DIR="${ROOT_DIR}/client/android/app/libs"
AAR_PATH="${OUTPUT_DIR}/libbox.aar"

echo "[1/5] Checking Go and gomobile environment..."
command -v go >/dev/null 2>&1 || { echo "ERROR: Go toolchain not found (need >= 1.26.1 for ${UPSTREAM_VERSION})."; exit 2; }

install_gomobile

if [ -z "${ANDROID_HOME:-}" ]; then
    echo "ERROR: ANDROID_HOME is not set; gomobile bind for Android needs the Android SDK."
    exit 2
fi
if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -z "${NDK:-}" ]; then
    echo "ERROR: ANDROID_NDK_HOME is not set; libbox needs NDK ${ANDROID_NDK_VERSION} (upstream pin)."
    exit 2
fi
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${NDK}}"

echo "[2/5] Verifying sing-box upstream source (${UPSTREAM_VERSION})..."
prepare_upstream

cd "${UPSTREAM_DIR}"

echo "[3/5] Compiling libbox.aar via gomobile (tags: ${UPSTREAM_BUILD_TAGS})..."
mkdir -p "${OUTPUT_DIR}"
rm -f "${AAR_PATH}"

gomobile bind \
    -target=android \
    -androidapi "${ANDROID_API_LEVEL}" \
    -javapkg=io.nekohasekai \
    -libname=box \
    -tags="${UPSTREAM_BUILD_TAGS}" \
    -trimpath -buildvcs=false \
    -ldflags="${UPSTREAM_LDFLAGS}" \
    -o "${AAR_PATH}" \
    ./experimental/libbox

echo "[4/5] Verifying artifact..."
if [ ! -f "${AAR_PATH}" ]; then
    echo "ERROR: gomobile did not produce ${AAR_PATH}."
    exit 1
fi
python3 "${ROOT_DIR}/scripts/verify_upstream_artifact.py" --aar "${AAR_PATH}"

echo "[5/5] Successfully generated a real libbox.aar in: ${AAR_PATH}"
