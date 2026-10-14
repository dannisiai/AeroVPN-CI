#!/usr/bin/env python3
"""Build the pinned upstream CLI for Intel/Apple Silicon macOS 13; never run it.

Requires Python 3.9+, Git and the exact Go version in core/upstream.env. Source,
module and compiler caches stay under core/upstream. No C compiler/SDK is used.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

from upstream_build import prepare_upstream

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "core/macos_build.json"
DEFAULT_OUTPUT = ROOT / "client/macos/Runner/sing-box"


def settings():
    return dict(re.findall(r'^([A-Z_]+)="([^"\r\n]*)"$',
                          (ROOT / "core/upstream.env").read_text(encoding="utf-8"), re.M))


def load_pin(version=None):
    config = settings()
    pin = json.loads(MANIFEST.read_text(encoding="utf-8"))
    for key, value in (("UPSTREAM_VERSION", "v" + pin["version"]),
                       ("UPSTREAM_COMMIT", pin["commit"]),
                       ("MACOS_GO_VERSION", pin["go_version"]),
                       ("UPSTREAM_BUILD_TAGS", pin["build_tags"]),
                       ("UPSTREAM_LDFLAGS", pin["ldflags"])):
        if config.get(key) != value:
            raise ValueError(f"Update core/macos_build.json to match {key}")
    if version and version.removeprefix("v") != pin["version"]:
        raise ValueError("macOS version must match core/upstream.env")
    return pin


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inspect_thin(data, info, check_hash=True):
    if len(data) < 32:
        raise ValueError("Truncated Mach-O executable")
    magic, cpu, subtype, kind, ncmds, cmdbytes, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype, kind) != (0xFEEDFACF, info["cputype"], info["cpusubtype"], 2):
        raise ValueError("Unexpected Mach-O architecture or file type")
    if ncmds == 0 or ncmds > 4096 or 32 + cmdbytes > len(data):
        raise ValueError("Invalid Mach-O load command table")
    offset = 32
    minimum_versions = []
    dylibs = []
    for _ in range(ncmds):
        if offset + 8 > 32 + cmdbytes:
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 8 or offset + size > 32 + cmdbytes:
            raise ValueError("Invalid Mach-O load command size")
        if command == 0x24 and size >= 16:
            minimum_versions.append(struct.unpack_from("<I", data, offset + 8)[0])
        elif command == 0x32 and size >= 24:
            platform, minos = struct.unpack_from("<II", data, offset + 8)
            if platform != 1:
                raise ValueError("Core must target macOS")
            minimum_versions.append(minos)
        elif command in (0xC, 0x80000018, 0x8000001F):
            if size < 24:
                raise ValueError("Truncated dylib command")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if name_offset < 24 or name_offset >= size:
                raise ValueError("Invalid dylib name offset")
            name = data[offset + name_offset:offset + size].split(b"\0", 1)[0].decode()
            dylibs.append(name)
        offset += size
    if offset != 32 + cmdbytes:
        raise ValueError("Invalid Mach-O load command count")
    major, minor, patch = map(int, info["minimum_macos"].split("."))
    if minimum_versions != [(major << 16) | (minor << 8) | patch]:
        raise ValueError("Core must actually declare the pinned minimum macOS version")
    # Go's pure Go Darwin resolver and crypto/x509 use these OS libraries.
    # CoreFoundation/Security are imported by crypto/x509/internal/macos even
    # with CGO=0; they do not introduce a dependency on the host Xcode SDK.
    if set(dylibs) - {"/usr/lib/libSystem.B.dylib", "/usr/lib/libresolv.9.dylib",
                     "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
                     "/System/Library/Frameworks/Security.framework/Versions/A/Security"}:
        raise ValueError(f"Unreviewed macOS dynamic dependency: {dylibs}")
    if check_hash and digest(data) != info["binary_sha256"]:
        raise ValueError("Core checksum differs from the reviewed source build")
    return {"minimum_macos": info["minimum_macos"], "sha256": digest(data), "dylibs": dylibs}


def inspect_metadata(path, arch, pin, env=None):
    # Reads Go build-info only; does not execute the target.
    if env is None:
        env = os.environ.copy()
        env.update({"GOTOOLCHAIN": "local", "GOENV": "off", "GOWORK": "off"})
    metadata = subprocess.check_output(["go", "version", "-m", str(path)], env=env, text=True)
    lines = [line.split() for line in metadata.splitlines()[1:]]
    build = dict(line[1].split("=", 1) for line in lines
                 if len(line) == 2 and line[0] == "build" and "=" in line[1])
    if not metadata.splitlines()[0].endswith("go" + pin["go_version"]):
        raise ValueError("Wrong Go compiler in core build metadata")
    for key, value in {"GOOS": "darwin", "GOARCH": arch, "CGO_ENABLED": "0",
                       "-tags": pin["build_tags"], "vcs.revision": pin["commit"],
                       "vcs.modified": "false", "-trimpath": "true"}.items():
        if build.get(key) != value:
            raise ValueError(f"Unexpected core build metadata {key}: {build.get(key)}")
    if arch == "amd64" and build.get("GOAMD64") != "v1":
        raise ValueError("Intel core must use baseline x86_64 instructions")
    if not any(line[:2] == ["path", "github.com/sagernet/sing-box/cmd/sing-box"] for line in lines):
        raise ValueError("Core is not the pinned sing-box CLI")
    if any("=>" in line for line in lines):
        raise ValueError("Unexpected module replacement in the core")
    # Go omits -ldflags from build-info with -trimpath. The reviewed build command
    # below supplies constant.Version; the manifest pins the resulting bytes.
    return metadata.splitlines()[1:]


def verify_universal(path, pin, metadata=True):
    data = Path(path).read_bytes()
    if len(data) < 48 or struct.unpack_from(">II", data) != (0xCAFEBABE, 2):
        raise ValueError("Core must be a universal Mach-O with two architectures")
    expected = {info["cputype"]: (arch, info) for arch, info in pin["assets"].items()}
    slices, ranges = [], []
    inspection_cache = ROOT / "core/upstream"
    inspection_cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aerovpn-macos-inspect-", dir=inspection_cache) as temp:
        for index in range(2):
            cpu, subtype, offset, size, align = struct.unpack_from(">5I", data, 8 + 20 * index)
            if cpu not in expected:
                raise ValueError("Unexpected or duplicate universal architecture")
            arch, info = expected.pop(cpu)
            if (subtype != info["cpusubtype"] or align != info["alignment"]
                    or offset < 48 or offset % (1 << align) or offset + size > len(data)):
                raise ValueError("Invalid universal slice bounds or alignment")
            if any(offset < end and start < offset + size for start, end in ranges):
                raise ValueError("Overlapping universal slices")
            ranges.append((offset, offset + size))
            thin = data[offset:offset + size]
            row = {"architecture": arch, "offset": offset, "size": size,
                   **inspect_thin(thin, info)}
            if metadata:
                target = Path(temp) / (arch + "-sing-box")
                target.write_bytes(thin)
                row["go_build_metadata"] = inspect_metadata(target, arch, pin)
            slices.append(row)
    return {"version": pin["version"], "commit": pin["commit"],
            "go_version": pin["go_version"], "size": len(data),
            "sha256": digest(data), "slices": slices}


def write_universal(path, slices, pin):
    # Standard Apple fat_header / fat_arch wrapper; executable bytes are unchanged.
    entries = []
    offset = 8 + 20 * len(slices)
    for arch, data in slices.items():
        info = pin["assets"][arch]
        alignment = 1 << info["alignment"]
        offset = (offset + alignment - 1) & ~(alignment - 1)
        if offset + len(data) >= 1 << 32:
            raise ValueError("Core is too large for a 32-bit fat_arch table")
        entries.append((info["cputype"], info["cpusubtype"], offset, len(data), info["alignment"]))
        offset += len(data)
    with path.open("wb") as output:
        output.write(struct.pack(">II", 0xCAFEBABE, len(slices)))
        for entry in entries:
            output.write(struct.pack(">5I", *entry))
        for entry, data in zip(entries, slices.values()):
            output.write(b"\0" * (entry[2] - output.tell()))
            output.write(data)


def build(output, cache, source, pin, update_checksums):
    config = settings()
    package_only = os.environ.get("AEROVPN_PACKAGE_ONLY") == "1"
    env = os.environ.copy()
    env.pop("GOROOT", None)
    env.update({"GOTOOLCHAIN": "local", "GOENV": "off", "GOWORK": "off",
                "GOPATH": str(cache / "gopath"), "GOMODCACHE": str(cache / "mod"),
                "GOCACHE": str(cache / "build"), "CGO_ENABLED": "0", "GOOS": "darwin",
                "GOFLAGS": "", "GOEXPERIMENT": "", "GOAMD64": "v1", "GOARM64": "v8.0",
                "GOSUMDB": "sum.golang.org", "GOPROXY": "https://proxy.golang.org,direct"})
    actual = subprocess.check_output(["go", "version"], env=env, text=True).split()[2]
    if actual != "go" + pin["go_version"]:
        raise ValueError(f"Install Go {pin['go_version']} first; found {actual}. No automatic toolchain download.")
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--config", "core.autocrlf=false", "--depth", "1",
                        "--branch", config["UPSTREAM_VERSION"], config["UPSTREAM_REPO"],
                        str(source)], check=True)
    prepare_upstream(config, source)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aerovpn-macos-build-", dir=output.parent) as temp:
        staging = Path(temp)
        slices = {}
        ldflags = pin["ldflags"] + " -X github.com/sagernet/sing-box/constant.Version=" + pin["version"]
        for arch, info in pin["assets"].items():
            target = staging / arch / "sing-box"
            target.parent.mkdir()
            env["GOARCH"] = arch
            print(f"Building upstream {pin['commit']} for darwin/{arch} using {actual}, CGO=0", flush=True)
            subprocess.run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=true",
                            "-tags", pin["build_tags"], "-ldflags", ldflags,
                            "-o", str(target), "./cmd/sing-box"], cwd=source, env=env, check=True)
            data = target.read_bytes()
            if not package_only:
                inspect_thin(data, info, check_hash=not update_checksums)
                inspect_metadata(target, arch, pin, env=env)
            slices[arch] = data
            if update_checksums:
                info["binary_sha256"] = digest(data)
        if not package_only:
            subprocess.run(["go", "mod", "verify"], cwd=source, env=env, check=True)
            prepare_upstream(config, source)  # -mod=readonly must leave the pin clean.
        candidate = staging / "sing-box"
        write_universal(candidate, slices, pin)
        result = ({"output": str(output), "package_only": True} if package_only
                  else verify_universal(candidate, pin))
        candidate.chmod(0o755)
        if update_checksums:
            MANIFEST.write_text(json.dumps(pin, indent=2) + "\n", encoding="utf-8")
        os.replace(candidate, output)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version")
    parser.add_argument("--cache-dir", type=Path, default=ROOT / "core/upstream/macos-build-cache")
    parser.add_argument("--source-dir", type=Path, default=ROOT / "core/upstream/sing-box-macos")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--verify", type=Path, help="Read build metadata and Mach-O headers; no build or target execution")
    parser.add_argument("--update-checksums", action="store_true",
                        help="Record a newly reviewed build in core/macos_build.json; inspect this diff on upgrades")
    args = parser.parse_args()
    pin = load_pin(args.version)
    if args.verify and args.update_checksums:
        parser.error("--verify cannot update build checksums")
    result = (verify_universal(args.verify, pin) if args.verify else
              build(args.output.resolve(), args.cache_dir.resolve(), args.source_dir.resolve(),
                    pin, args.update_checksums))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"ERROR: {error}")
