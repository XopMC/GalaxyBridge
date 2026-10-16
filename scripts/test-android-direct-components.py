#!/usr/bin/env python3
"""Verify that every shell-only Direct component is actually present in DEX."""

import argparse
import hashlib
from pathlib import Path
import zipfile


REQUIRED_CLASSES = (
    "com.xopmc.galaxybridge.catalog.ApplicationCatalogExportReceiver",
    "com.xopmc.galaxybridge.service.RemoteTextInputReceiver",
    "com.xopmc.galaxybridge.transport.shell.ShellBridgeActivationReceiver",
    "com.xopmc.galaxybridge.transport.shell.ShellBridgeAttachProvider",
)

FORBIDDEN_CLASSES = (
    "com.xopmc.galaxybridge.internet.InternetGatewayQaReceiver",
    "com.xopmc.galaxybridge.internet.InternetGatewayQaGuard",
    "com.xopmc.galaxybridge.transport.shell.ShellBridgeQaReceiver",
    "com.xopmc.galaxybridge.service.NotificationReplyQaReceiver",
    "com.xopmc.galaxybridge.service.TextInputQaActivity",
    "com.xopmc.galaxybridge.service.ClipboardPasteQaActivity",
    "com.xopmc.galaxybridge.transport.DownloadsProviderQaReceiver",
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()

    with zipfile.ZipFile(args.apk) as archive:
        dex_files = [archive.read(name) for name in archive.namelist() if name.endswith(".dex")]
        notices = archive.read('assets/InternetRuntime-NOTICES.txt')
        expected = Path(__file__).resolve().parents[1] / 'native/galaxybridge-internet/THIRD_PARTY_NOTICES.txt'
        if hashlib.sha256(notices).digest() != hashlib.sha256(expected.read_bytes()).digest():
            raise SystemExit('Android native runtime notices do not match the distributed source notices.')
        for abi in ('arm64-v8a', 'x86_64'):
            if 'lib/' + abi + '/libgalaxybridge_internet.so' not in archive.namelist():
                raise SystemExit('Direct APK is missing native internet gateway ABI: ' + abi)
    if not dex_files:
        raise SystemExit(f"No DEX files found in {args.apk}")

    missing = []
    for class_name in REQUIRED_CLASSES:
        descriptor = ("L" + class_name.replace(".", "/") + ";").encode("ascii")
        if not any(descriptor in dex for dex in dex_files):
            missing.append(class_name)
    if missing:
        raise SystemExit("Direct APK is missing manifest components: " + ", ".join(missing))
    for class_name in FORBIDDEN_CLASSES:
        descriptor = ("L" + class_name.replace(".", "/") + ";").encode("ascii")
        if any(descriptor in dex for dex in dex_files):
            raise SystemExit('Internal QA bytecode is forbidden in Direct release: ' + class_name)
    print("Direct APK components, native ABIs and notices verified; internal QA bytecode absent.")


if __name__ == "__main__":
    main()
