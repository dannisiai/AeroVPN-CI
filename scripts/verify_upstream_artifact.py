#!/usr/bin/env python3
"""AeroVPN - upstream core artifact verifier (static, no execution).

Guards against the failure mode this repo already hit once: a *placeholder*
libbox.aar / Libbox.xcframework (hand-written stub classes, no native code)
being committed or bundled, which compiles but can never start a tunnel.

Checks performed (all static):
  --aar          real gomobile AAR: >= min size, jni/<abi>/*.so present for the
                 ARM ABIs, and classes.jar still exposes the exact libbox classes
                 the Android host looks up reflectively (v1.13+ API surface).
  --xcframework  real gomobile Apple framework: every slice binary >= min size and
                 the generated header exposing the v1.13+ API the Swift host uses
                 (LibboxSetup / LibboxNewCommandServer / ... instead of the removed
                 LibboxNewService-only stub header).

Exit code is non-zero on any failure so build scripts / CI stop early.
"""

import argparse
import hashlib
import io
import os
import re
import sys
import zipfile

MIN_SIZE_MB = 5

# Classes the Android host resolves by name via reflection (AeroVpnService.kt).
REQUIRED_AAR_CLASSES = [
    "io/nekohasekai/libbox/Libbox.class",
    "io/nekohasekai/libbox/SetupOptions.class",      # v1.13+ API
    "io/nekohasekai/libbox/PlatformInterface.class",
    "io/nekohasekai/libbox/CommandServer.class",     # v1.13+ API
    "io/nekohasekai/libbox/CommandServerHandler.class",
    "io/nekohasekai/libbox/OverrideOptions.class",
    "io/nekohasekai/libbox/StringIterator.class",
    "io/nekohasekai/libbox/NetworkInterfaceIterator.class",
    "io/nekohasekai/libbox/NetworkInterface.class",
    "io/nekohasekai/libbox/ConnectionOwner.class",
    "io/nekohasekai/libbox/LocalDNSTransport.class",
    "io/nekohasekai/libbox/ExchangeContext.class",
]
REQUIRED_ABIS = ["arm64-v8a", "armeabi-v7a"]

# Slice binaries the app links. The product ships iOS only; the macOS slice is not
# built (desktop uses the standalone sing-box binary) and the simulator slice is
# omitted from the committed framework because it exceeds GitHub's 100 MB/file
# limit, so only the device slice is required here.
REQUIRED_XCFRAMEWORK_SLICES = [
    "ios-arm64/Libbox.framework/Libbox",
]

# Symbols the Swift host implements / calls. Names are the gomobile-generated ObjC
# spellings (see gomobile bind/genobjc.go: `@protocol <Prefix><GoName>`, top-level
# funcs `<Prefix><Name>`). A header that only declares LibboxNewService is the
# pre-v1.13 stub and cannot compile the current PacketTunnelProvider, so at least
# one v1.13+ entry point and the platform/handler protocols must be present. The
# protocol interfaces are emitted into the generated transport file, so this list is
# split and each symbol may appear in any public header of the framework.
REQUIRED_XCFRAMEWORK_SYMBOLS = [
    # v1.13+ entry points / types
    "LibboxSetup",
    "LibboxSetupOptions",
    "LibboxNewCommandServer",
    "LibboxCommandServer",
    "LibboxOverrideOptions",
    "LibboxGetTunnelFileDescriptor",
    # protocols the Swift packet-tunnel provider conforms to / uses
    "LibboxPlatformInterface",
    "LibboxCommandServerHandler",
    "LibboxTunOptions",
    "LibboxInterfaceUpdateListener",
]
# The stub header is exactly this and nothing else; require at least one of the
# v1.13+ entry points to be present in addition.
REQUIRED_ANY_NEW_API = [
    "LibboxSetup",
    "LibboxNewCommandServer",
]

# wintun 0.14.1 amd64, downloaded from the official distribution
# (https://www.wintun.net/builds/wintun-0.14.1.zip, bin/amd64/wintun.dll).
# The DLL is loaded by a SYSTEM-privileged process, so its integrity is
# verified against this pin instead of being trusted as-is (M5).
WINTUN_OFFICIAL_SHA256 = "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce"


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg):
    print(f"  OK: {msg}")


def check_aar(path, min_size_mb):
    if not os.path.isfile(path):
        fail(f"AAR not found: {path}")
    size = os.path.getsize(path)
    print(f"Verifying AAR {path} ({size} bytes)")
    if size < min_size_mb * 1024 * 1024:
        fail(
            f"{path} is only {size} bytes (< {min_size_mb} MB): this is a placeholder "
            "stub, not a gomobile build. Rebuild with core/scripts/build_android_aar.sh."
        )

    try:
        with zipfile.ZipFile(path) as aar:
            names = aar.namelist()
            if "classes.jar" not in names:
                fail(f"{path} has no classes.jar - not a valid AAR.")
            classes_bytes = aar.read("classes.jar")
    except zipfile.BadZipFile as exc:
        fail(f"{path} is not a valid zip/AAR: {exc}")

    sos = [n for n in names if n.startswith("jni/") and n.endswith(".so")]
    if not sos:
        fail(f"{path} contains no jni/<abi>/*.so - placeholder stub, tunnel cannot run.")
    ok(f"native libraries: {len(sos)} (.so)")

    for abi in REQUIRED_ABIS:
        if not any(n.startswith(f"jni/{abi}/") for n in sos):
            fail(f"{path} is missing the {abi} native library.")
    ok(f"ABIs present: {', '.join(REQUIRED_ABIS)}")

    with zipfile.ZipFile(io.BytesIO(classes_bytes)) as jar:
        jar_names = set(jar.namelist())
    missing = [c for c in REQUIRED_AAR_CLASSES if c not in jar_names]
    if missing:
        fail(
            "AAR is missing libbox v1.13+ classes the Android host needs: "
            + ", ".join(missing)
            + ". This is either a stub AAR or a core built from an older release."
        )
    ok(f"libbox v1.13+ classes present ({len(REQUIRED_AAR_CLASSES)} checked)")
    print("PASS: real libbox.aar")


def check_xcframework(path, min_size_mb):
    if not os.path.isdir(path):
        fail(f"xcframework not found: {path}")
    print(f"Verifying xcframework {path}")

    for rel in REQUIRED_XCFRAMEWORK_SLICES:
        binary = os.path.join(path, rel.replace("/", os.sep))
        if not os.path.isfile(binary):
            fail(f"{path} is missing the {rel} slice - placeholder or incomplete build.")
        # The framework is a versioned bundle: the top-level `Libbox` is a symlink to
        # Versions/Current/Libbox. Git checkouts without symlink support (e.g. Windows)
        # materialise that link as a tiny text file, so resolve to the real binary by
        # taking the largest file named "Libbox" under the slice directory.
        slice_dir = os.path.dirname(binary)
        candidates = []
        for root, _dirs, files in os.walk(slice_dir):
            for name in files:
                if name == os.path.basename(rel):
                    candidates.append(os.path.join(root, name))
        real_binaries = [p for p in candidates if os.path.getsize(p) >= min_size_mb * 1024 * 1024]
        if not real_binaries:
            size = os.path.getsize(binary)
            fail(
                f"{rel} resolves to only {size} bytes (< {min_size_mb} MB): placeholder stub, "
                "not a gomobile build. Rebuild with core/scripts/build_apple_xcframework.sh."
            )
        size = max(os.path.getsize(p) for p in real_binaries)
        ok(f"{rel}: {size} bytes")

    headers = []
    for root, _dirs, files in os.walk(path):
        headers.extend(
            os.path.join(root, name) for name in files if name.endswith(".h")
        )
    if not headers:
        fail(f"{path} contains no public header - not a usable framework.")

    combined = ""
    for header in headers:
        with open(header, "r", encoding="utf-8", errors="replace") as handle:
            combined += handle.read()
    missing = [s for s in REQUIRED_XCFRAMEWORK_SYMBOLS if not re.search(rf"\b{s}\b", combined)]
    if missing:
        fail(
            "framework header is missing libbox symbols: "
            + ", ".join(missing)
            + " (a pre-v1.13 stub header only declares LibboxNewService and cannot compile "
            "the current PacketTunnelProvider)."
        )
    if not any(re.search(rf"\b{s}\b", combined) for s in REQUIRED_ANY_NEW_API):
        fail(
            "framework header declares no libbox v1.13+ entry point ("
            + "/".join(REQUIRED_ANY_NEW_API)
            + "); it is the removed pre-v1.13 API and cannot start a tunnel."
        )
    ok(f"libbox v1.13+ header symbols present ({len(REQUIRED_XCFRAMEWORK_SYMBOLS)} checked)")
    print("PASS: real Libbox.xcframework")


def check_wintun(path):
    if not os.path.isfile(path):
        fail(f"wintun.dll not found: {path}")
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != WINTUN_OFFICIAL_SHA256:
        fail(
            f"{path} sha256 {actual} does not match the official wintun 0.14.1 amd64 "
            f"build ({WINTUN_OFFICIAL_SHA256}). Replace it from "
            "https://www.wintun.net/builds/wintun-0.14.1.zip (bin/amd64/wintun.dll) - "
            "a SYSTEM-privileged process loads this file, so it must be bit-identical."
        )
    ok(f"wintun.dll sha256 matches official wintun 0.14.1 amd64")
    print("PASS: authentic wintun.dll")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aar", help="path to client/android/app/libs/libbox.aar")
    parser.add_argument("--xcframework", help="path to client/ios/Frameworks/Libbox.xcframework")
    parser.add_argument("--wintun", help="path to core/daemon/wintun.dll")
    parser.add_argument("--min-size-mb", type=int, default=MIN_SIZE_MB)
    args = parser.parse_args()

    if not args.aar and not args.xcframework and not args.wintun:
        parser.error("pass --aar and/or --xcframework and/or --wintun")
    if args.aar:
        check_aar(args.aar, args.min_size_mb)
    if args.xcframework:
        check_xcframework(args.xcframework, args.min_size_mb)
    if args.wintun:
        check_wintun(args.wintun)


if __name__ == "__main__":
    main()
