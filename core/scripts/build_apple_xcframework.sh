#!/usr/bin/env bash
# ==============================================================================
# AeroVPN - Apple (iOS / macOS) Libbox.xcframework Build Script
# Targets: ios, iossimulator, macos
# NetworkExtension compatible build
#
# Mirrors the upstream build recipe (Makefile: lib_apple, and
# cmd/internal/build_libbox -target apple): upstream gomobile fork, pinned release
# tag, upstream build tags, deployment targets. Version/tags live in core/upstream.env.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../upstream.env
source "${ROOT_DIR}/core/upstream.env"
source "${SCRIPT_DIR}/upstream_build_common.sh"

UPSTREAM_DIR="${ROOT_DIR}/core/upstream/sing-box"
OUTPUT_DIR="${ROOT_DIR}/client/ios/Frameworks"
XCFRAMEWORK_PATH="${OUTPUT_DIR}/Libbox.xcframework"

echo "[1/5] Ensuring Go and upstream gomobile (${GOMOBILE_VERSION})..."
command -v go >/dev/null 2>&1 || { echo "ERROR: Go toolchain not found (need >= 1.26.1 for ${UPSTREAM_VERSION})."; exit 2; }

install_gomobile

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "ERROR: Xcode command line tools are required to build Libbox.xcframework."
    exit 2
fi

echo "[2/5] Preparing upstream source (${UPSTREAM_VERSION})..."
prepare_upstream

cd "${UPSTREAM_DIR}"

echo "[3/5] Compiling Libbox.xcframework (tags: ${UPSTREAM_BUILD_TAGS})..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${XCFRAMEWORK_PATH}"

gomobile bind \
    -target=ios \
    -libname=box \
    -iosversion=15.0 \
    -tags="${UPSTREAM_BUILD_TAGS}" \
    -trimpath -buildvcs=false \
    -ldflags="${UPSTREAM_LDFLAGS}" \
    -o "${XCFRAMEWORK_PATH}" \
    ./experimental/libbox

echo "[4/5] Verifying artifact..."
python3 "${ROOT_DIR}/scripts/verify_upstream_artifact.py" --xcframework "${XCFRAMEWORK_PATH}"

echo "[5/5] Successfully generated a real Libbox.xcframework in: ${XCFRAMEWORK_PATH}"
