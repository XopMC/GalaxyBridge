#!/usr/bin/env python3
"""Create a GitHub/ad-hoc app and drag-to-Applications DMG.

Defaults to candidate metadata. Explicit --release labels the agreed 0.1.1
Direct scope; it does not notarize, install, publish, or certify hardware tests.
All source bundle changes happen in an owned staging copy.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

VERSION = "0.1.1"

def distribution_metadata(release: bool) -> dict:
    return {
        "CFBundleIdentifier": "com.xopmc.GalaxyBridge",
        "CFBundleName": "Galaxy Bridge",
        "GalaxyBridgeDistribution": "github-direct",
        "GalaxyBridgeReleaseStatus": "release" if release else "candidate",
        "GalaxyBridgeCameraExtensionProvisioned": False,
    }


def installation_text(release: bool) -> str:
    title = f"Direct release {VERSION}" if release else "GitHub direct candidate"
    return (
        f"Galaxy Bridge - {title}, macOS 14+, Apple Silicon\n\n"
        "Open the DMG and drag Galaxy Bridge.app to Applications. ADB and its\n"
        "dependencies are included. Android SDK and Homebrew are not needed.\n\n"
        "This build uses local ad-hoc signing, with no Apple notarization. macOS\n"
        "may block a downloaded build; review it and use System Settings >\n"
        "Privacy & Security > Open Anyway if you choose to run it.\n\n"
        + (
            f"RELEASE {VERSION} SCOPE: Message replies use supported notification\n"
            "actions only. Full SMS history and direct SMS sending are not included.\n"
            "Virtual webcam support is not included in this release. The Camera\n"
            "Extension remains embedded, but activation requires suitable Apple\n"
            "provisioning and signing; its presence does not enable a virtual webcam.\n\n"
            "The release label does not certify every device, network, clean-Mac\n"
            "installation or upgrade scenario. See the release notes for the tested\n"
            "configurations and known limitations.\n"
            if release else
            "KNOWN BLOCKER: macOS Camera Extension activation requires an Apple\n"
            "provisioned signing identity. The real extension is still embedded;\n"
            "virtual webcam availability is NOT claimed for this ad-hoc candidate.\n"
            "Functional acceptance, clean-Mac launch and upgrade checks remain\n"
            "separate release gates. This directory is not a publication approval.\n"
        )
    )


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source_app", type=Path)
parser.add_argument("output_directory", type=Path)
parser.add_argument("--adb-runtime", type=Path, default=ROOT / ".build/owned-adb/runtime-v2.2")
parser.add_argument("--release", action="store_true",
                    help="Label Direct release 0.1.1 (notification replies only, no virtual webcam).")
args = parser.parse_args()
source, output, runtime = (p.resolve() for p in (args.source_app, args.output_directory, args.adb_runtime))
if output.exists() or source == output or source in output.parents:
    raise SystemExit("Choose a new output directory outside the source app.")
if not (source / "Contents/Info.plist").is_file():
    raise SystemExit("Source app is missing.")
for name in ("adb", "libusb-1.0.0.dylib", "NOTICE", "PROVENANCE.json", "SHA256SUMS", "OWNED-CONTRACT.json", "libusb-1.0.29-source.tar.gz"):
    if not (runtime / name).is_file():
        raise SystemExit("Source-built ADB runtime missing: " + name)
contract = json.loads((runtime / "OWNED-CONTRACT.json").read_text())
if contract.get("contract") != "galaxybridge-owned-adb-v2" or contract.get("usb_policy") != "nonseizing-v1":
    raise SystemExit("Verified owned ADB v2 with nonseizing USB is required.")
pins_path = source / "Contents/Resources/BuildArtifacts.json"
if not pins_path.is_file():
    raise SystemExit("Source app has no build provenance; build it with the CMake macos-app target.")
build_pins = json.loads(pins_path.read_text())
expected_adb = build_pins.get("adbSHA", "")
expected_usb = build_pins.get("libusbSHA", "")
if not re.fullmatch(r"[0-9a-f]{64}", expected_adb) or not re.fullmatch(r"[0-9a-f]{64}", expected_usb):
    raise SystemExit("Invalid compiled-artifact provenance.")
if contract.get("adb_sha256") != expected_adb or contract.get("libusb_sha256") != expected_usb:
    raise SystemExit("Runtime differs from the source app's compiled build inputs.")
for name, field in (("adb", "adb_sha256"), ("libusb-1.0.0.dylib", "libusb_sha256")):
    if hashlib.sha256((runtime / name).read_bytes()).hexdigest() != contract.get(field):
        raise SystemExit("Owned runtime contract hash failed: " + name)
subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=runtime,
               check=True, stdout=subprocess.DEVNULL)
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".galaxybridge-direct-", dir=output.parent) as temporary:
    stage = Path(temporary) / "candidate"
    stage.mkdir()
    app = stage / "Galaxy Bridge.app"
    subprocess.run(["ditto", str(source), str(app)], check=True)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(distribution_metadata(args.release))
    info_path.write_bytes(plistlib.dumps(info))
    adb_directory = app / "Contents/Resources/platform-tools"
    if adb_directory.exists():
        shutil.rmtree(adb_directory)
    shutil.copytree(runtime, adb_directory)
    executables = [adb_directory / "libusb-1.0.0.dylib", adb_directory / "adb"]
    host = app / "Contents/MacOS" / info["CFBundleExecutable"]
    extensions = list((app / "Contents/Library/SystemExtensions").glob("*.systemextension"))
    if not extensions:
        raise SystemExit("Camera Extension must remain embedded; missing source extension.")
    for extension in extensions:
        extension_info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
        executables.append(extension / "Contents/MacOS" / extension_info["CFBundleExecutable"])
    executables.append(host)
    for executable in executables:
        subprocess.run(["lipo", str(executable), "-verify_arch", "arm64"], check=True)
        libraries = subprocess.check_output(["otool", "-L", str(executable)], text=True)
        for line in libraries.splitlines():
            if " (compatibility" not in line:
                continue
            dependency = line.strip().split(" (compatibility")[0]
            if not dependency.startswith(("/usr/lib/", "/System/Library/")):
                if dependency not in ("@executable_path/libusb-1.0.0.dylib", "@loader_path/libusb-1.0.0.dylib"):
                    raise SystemExit("Unbundled Mach-O dependency: " + dependency)
        subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(executable)], check=True)
    # No hardened-runtime library validation: users can replace LGPL libusb.
    for extension in extensions:
        subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(extension)], check=True)
    if hashlib.sha256((adb_directory / "adb").read_bytes()).hexdigest() != expected_adb:
        raise SystemExit("Signing changed the pinned ADB artifact; review and update the application pin before release.")
    if hashlib.sha256((adb_directory / "libusb-1.0.0.dylib").read_bytes()).hexdigest() != expected_usb:
        raise SystemExit("Signing changed the compiled libusb pin; rebuild the app with final artifact bytes.")
    # Re-run the real owned artifact contract after signing, using private
    # USB-disabled fixtures only, then refresh the exact sealed binary hashes.
    subprocess.run(["python3", str(ROOT / "scripts/test-owned-adb-artifact.py"),
                    str(adb_directory / "adb"), "--write-contract"], check=True)
    manifest = []
    for path in sorted(adb_directory.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS":
            manifest.append(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path.relative_to(adb_directory)))
    (adb_directory / "SHA256SUMS").write_text("\n".join(manifest) + "\n")
    subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    # Running adb version does not start a server or touch any phone.
    version_keys = Path(temporary) / "version-keys"
    version_keys.mkdir(mode=0o700)
    subprocess.run(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin",
                    "GALAXYBRIDGE_ADB_USER_DIR=" + str(version_keys), str(adb_directory / "adb"), "version"], check=True)
    dmg = stage / f"GalaxyBridge-{VERSION}-macOS-arm64.dmg"
    subprocess.run(["sh", str(ROOT / "scripts/create-macos-dmg-layout.sh"), str(app), str(dmg)], check=True)
    (stage / "INSTALL.txt").write_text(installation_text(args.release))
    (stage / "SHA256SUMS").write_text(hashlib.sha256(dmg.read_bytes()).hexdigest() + "  " + dmg.name + "\n")
    # mkdir is no-clobber; move only into the directory we exclusively created.
    output.mkdir()
    for path in stage.iterdir():
        shutil.move(str(path), str(output / path.name))
label = f"Direct release {VERSION}" if args.release else "GitHub/ad-hoc candidate"
print(f"Created self-contained {label}: {output}")
if args.release:
    print("Release scope: notification replies only; no full SMS history/sending or virtual webcam.")
    print("Ad-hoc signed, not notarized. Hardware coverage is limited to documented checks. Nothing published.")
else:
    print("Camera activation and functional release gates remain open. Nothing published.")
