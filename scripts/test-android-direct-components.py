#!/usr/bin/env python3
"""Verify that every shell-only Direct component is actually present in DEX."""

import argparse
from pathlib import Path
import zipfile


REQUIRED_CLASSES = (
    "com.xopmc.galaxybridge.catalog.ApplicationCatalogExportReceiver",
    "com.xopmc.galaxybridge.service.RemoteTextInputReceiver",
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()

    with zipfile.ZipFile(args.apk) as archive:
        dex_files = [archive.read(name) for name in archive.namelist() if name.endswith(".dex")]
    if not dex_files:
        raise SystemExit(f"No DEX files found in {args.apk}")

    missing = []
    for class_name in REQUIRED_CLASSES:
        descriptor = ("L" + class_name.replace(".", "/") + ";").encode("ascii")
        if not any(descriptor in dex for dex in dex_files):
            missing.append(class_name)
    if missing:
        raise SystemExit("Direct APK is missing manifest components: " + ", ".join(missing))
    print("Direct APK contains all shell-only manifest components.")


if __name__ == "__main__":
    main()
