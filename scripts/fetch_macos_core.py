#!/usr/bin/env python3
"""Compatibility entry point: macOS cores are built from pinned upstream source."""
import subprocess
import sys
from build_macos_core import main

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"ERROR: {error}")
