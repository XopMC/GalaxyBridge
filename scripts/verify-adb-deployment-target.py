#!/usr/bin/env python3
"""Fail if a built Mach-O object silently targets a newer client OS than 14.0."""
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1]).resolve()
checked = 0
for path in root.rglob("*.o"):
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        continue
    offset, versions = 32, []
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x32:  # LC_BUILD_VERSION
            versions.append(struct.unpack_from("<I", data, offset + 12)[0])
        elif command == 0x24:  # LC_VERSION_MIN_MACOSX
            versions.append(struct.unpack_from("<I", data, offset + 8)[0])
        offset += size
    if not versions or any(version > 14 << 16 for version in versions):
        raise SystemExit("ADB object lacks a compatible macOS deployment target: " + str(path))
    checked += 1
if not checked:
    raise SystemExit("No built Mach-O objects found; deployment contract was not checked.")
print(f"ADB deployment target passed: {checked} Mach-O objects target macOS 14.0 or earlier.")
