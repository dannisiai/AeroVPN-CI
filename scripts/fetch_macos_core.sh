#!/usr/bin/env bash
# Build both macOS 13 slices from pinned upstream source without executing them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -gt 0 ]; then
  exec python3 "${SCRIPT_DIR}/build_macos_core.py" --version "$1"
fi
exec python3 "${SCRIPT_DIR}/build_macos_core.py"
