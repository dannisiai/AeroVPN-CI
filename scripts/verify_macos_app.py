#!/usr/bin/env python3
"""Inspect a built macOS app's architecture coverage and minimum OS; never run it."""

import argparse
import json
from pathlib import Path
import plistlib
import struct
import sys

ARCHITECTURES = {0x1000007: "x86_64", 0x100000C: "arm64"}


def version_number(value):
    parts = [int(part) for part in value.split(".")]
    if not 1 <= len(parts) <= 3 or any(part < 0 or part > 255 for part in parts):
        raise ValueError(f"Invalid macOS version: {value}")
    parts += [0] * (3 - len(parts))
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def image_versions(data):
    """Return None for resources, else all Mach-O slice minimum versions."""
    if len(data) < 4:
        return None
    magic = struct.unpack_from(">I", data)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        if len(data) < 8:
            raise ValueError("Truncated fat Mach-O")
        count = struct.unpack_from(">I", data, 4)[0]
        entry_size = 20 if magic == 0xCAFEBABE else 32
        if count == 0 or count > 32 or 8 + count * entry_size > len(data):
            raise ValueError("Invalid fat Mach-O table")
        images, ranges = {}, []
        for i in range(count):
            values = struct.unpack_from(">5I" if entry_size == 20 else ">IIQQII", data, 8 + i * entry_size)
            cpu, _, offset, size, alignment = values[:5]
            if (alignment > 30 or offset < 8 + count * entry_size
                    or offset % (1 << alignment) or size < 32 or offset + size > len(data)
                    or any(offset < end and start < offset + size for start, end in ranges)):
                raise ValueError("Invalid fat Mach-O slice bounds")
            ranges.append((offset, offset + size))
            image = image_versions(data[offset:offset + size])
            if image is None or len(image) != 1 or ARCHITECTURES.get(cpu) not in image:
                raise ValueError("Fat Mach-O CPU disagrees with its slice")
            if images.keys() & image.keys():
                raise ValueError("Duplicate Mach-O architecture")
            images.update(image)
        return images
    if magic in (0xFEEDFACE, 0xCEFAEDFE, 0xFEEDFACF):
        raise ValueError("Unsupported 32-bit or big-endian Mach-O")
    if magic != 0xCFFAEDFE:
        return None
    if len(data) < 32:
        raise ValueError("Truncated Mach-O header")
    _, cpu, _, _, count, size, _, _ = struct.unpack_from("<8I", data)
    if cpu not in ARCHITECTURES or count == 0 or count > 4096 or 32 + size > len(data):
        raise ValueError("Invalid Mach-O header")
    offset, minimums = 32, []
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise ValueError("Truncated load command")
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or length % 8 or offset + length > 32 + size:
            raise ValueError("Invalid load command")
        if command == 0x24 and length >= 16:
            minimums.append(struct.unpack_from("<I", data, offset + 8)[0])
        elif command == 0x32 and length >= 24:
            platform, minimum = struct.unpack_from("<II", data, offset + 8)
            if platform != 1:
                raise ValueError("Embedded executable targets a non-macOS platform")
            minimums.append(minimum)
        offset += length
    if offset != 32 + size or len(minimums) != 1:
        raise ValueError("Missing or conflicting minimum macOS load command")
    return {ARCHITECTURES[cpu]: minimums[0]}


def verify_app(app, minimum="13.0.0"):
    target = version_number(minimum)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if version_number(info["LSMinimumSystemVersion"]) != target:
        raise ValueError("App Info.plist disagrees with the requested minimum macOS")
    by_arch = info["LSMinimumSystemVersionByArchitecture"]
    if any(version_number(by_arch[arch]) != target for arch in ARCHITECTURES.values()):
        raise ValueError("Architecture-specific app minimum differs from the requested macOS")
    main = app / "Contents/MacOS" / info["CFBundleExecutable"]
    core = app / "Contents/MacOS/sing-box"
    if not main.is_file() or not core.is_file():
        raise ValueError("Missing app executable or bundled proxy core")
    rows, seen = [], set()
    for path in sorted((app / "Contents").rglob("*")):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        # Avoid loading large non-executable resource files.
        with path.open("rb") as stream:
            header = stream.read(4)
        if header not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xcf\xfa\xed\xfe",
                          b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
            continue
        images = image_versions(path.read_bytes())
        if set(images) != set(ARCHITECTURES.values()) or any(v > target for v in images.values()):
            raise ValueError(f"{path}: requires a newer OS or lacks Intel/Apple Silicon coverage")
        rows.append({"path": path.relative_to(app).as_posix(), "minimums": images})
    if not any(row["path"] == "Contents/MacOS/sing-box" for row in rows):
        raise ValueError("Bundled core is not a Mach-O executable")
    if not any(row["path"] == "Contents/MacOS/" + info["CFBundleExecutable"] for row in rows):
        raise ValueError("App main executable is not a Mach-O executable")
    return {"app": str(app), "minimum_macos": minimum, "images": rows}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify_app(args.app), indent=2))
    except (OSError, ValueError, KeyError, struct.error) as error:
        sys.exit(f"ERROR: {error}")
