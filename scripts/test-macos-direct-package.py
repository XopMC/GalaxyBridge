#!/usr/bin/env python3
"""Real DMG/ad-hoc/dependency checks, using a tiny C executable as a bounded host fixture."""
from pathlib import Path
import hashlib
import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
# Load only the configuration surface, stopping before any filesystem/runtime
# checks. This mode needs no compiler, ADB, signing, DMG or application launch.
class ConfigurationLoaded(Exception):
    pass

spec = importlib.util.spec_from_file_location("direct_package_policy", ROOT / "scripts/package-macos-direct.py")
policy = importlib.util.module_from_spec(spec)
with mock.patch("argparse.ArgumentParser.parse_args", side_effect=ConfigurationLoaded), mock.patch.object(sys, "dont_write_bytecode", True):
    try:
        spec.loader.exec_module(policy)
    except ConfigurationLoaded:
        pass
candidate = policy.parser.parse_args(["Source.app", "new-output"])
release = policy.parser.parse_args(["Source.app", "new-output", "--release"])
assert candidate.release is False and release.release is True
for arguments, status in ((candidate, "candidate"), (release, "release")):
    info = {"CFBundleVersion": "7", "CFBundleExecutable": "GalaxyBridgeMac"}
    info.update(policy.distribution_metadata(arguments.release))
    sealed = plistlib.loads(plistlib.dumps(info))
    assert sealed["GalaxyBridgeReleaseStatus"] == status
    assert sealed["GalaxyBridgeDistribution"] == "github-direct"
    assert sealed["GalaxyBridgeCameraExtensionProvisioned"] is False
    assert sealed["CFBundleVersion"] == "7" and sealed["CFBundleExecutable"] == "GalaxyBridgeMac"
    text = policy.installation_text(arguments.release)
    assert "local ad-hoc signing" in text and "no Apple notarization" in text
    assert "drag Galaxy Bridge.app to Applications" in text
assert "direct candidate" in policy.installation_text(False)
release_text = policy.installation_text(True)
assert "Direct release 0.1.0" in release_text
assert "Full SMS history and direct SMS sending are not included" in release_text
assert "Virtual webcam support is not included" in release_text
assert "Extension remains embedded" in release_text
assert "does not certify every device" in release_text
print("Direct package metadata: candidate default, explicit release scope, embedded unprovisioned extension and honest install instructions passed.")
if sys.argv[1:] == ["--metadata-only"]:
    raise SystemExit(0)
if sys.argv[1:]:
    raise SystemExit("Only --metadata-only is supported")

runtime = Path(os.environ.get("GB_ADB_RUNTIME", str(ROOT / "out/macos-arm64-release/artifacts/adb")))
if not runtime.is_dir():
    raise SystemExit("Build real adb first with scripts/build-owned-adb.sh")
with tempfile.TemporaryDirectory(prefix="gb-direct-package-") as temporary:
    work = Path(temporary)
    fixture = work / "host-fixture"
    subprocess.run(["clang", "-arch", "arm64", "-x", "c", "-", "-o", str(fixture)],
                   input="int main(void) { return 0; }\n", text=True, check=True)
    app = work / "Source.app"
    extension = app / "Contents/Library/SystemExtensions/com.xopmc.GalaxyBridge.CameraExtension.systemextension"
    for bundle, name, identifier in ((app, "GalaxyBridgeMac", "com.xopmc.GalaxyBridge.internal"),
                                      (extension, "GalaxyBridgeCameraExtension", "com.xopmc.GalaxyBridge.CameraExtension")):
        (bundle / "Contents/MacOS").mkdir(parents=True)
        shutil.copyfile(fixture, bundle / "Contents/MacOS" / name)
        (bundle / "Contents/MacOS" / name).chmod(0o755)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL" if bundle == app else "SYSX", "CFBundleVersion": "1"}))
    resources = app / "Contents/Resources"
    resources.mkdir()
    (resources / "BuildArtifacts.json").write_text(__import__("json").dumps({
        "adbSHA": hashlib.sha256((runtime / "adb").read_bytes()).hexdigest(),
        "libusbSHA": hashlib.sha256((runtime / "libusb-1.0.0.dylib").read_bytes()).hexdigest(),
    }))
    source_hash = hashlib.sha256((app / "Contents/Info.plist").read_bytes()).hexdigest()
    output = work / "candidate"
    command = [sys.executable, str(ROOT / "scripts/package-macos-direct.py"), str(app), str(output), "--release", "--adb-runtime", str(runtime)]
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    assert source_hash == hashlib.sha256((app / "Contents/Info.plist").read_bytes()).hexdigest()
    result = output / "Galaxy Bridge.app"
    assert hashlib.sha256((result / "Contents/Resources/platform-tools/adb").read_bytes()).hexdigest() == hashlib.sha256((runtime / "adb").read_bytes()).hexdigest(), "ad-hoc re-sign must preserve the reviewed pinned ADB bytes"
    info = plistlib.loads((result / "Contents/Info.plist").read_bytes())
    assert info["GalaxyBridgeReleaseStatus"] == "release"
    assert "Direct release 0.1.0" in (output / "INSTALL.txt").read_text()
    assert info["GalaxyBridgeDistribution"] == "github-direct"
    assert info["CFBundleIdentifier"] == "com.xopmc.GalaxyBridge"
    assert info["GalaxyBridgeCameraExtensionProvisioned"] is False
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(result)], check=True)
    probe = work / "version-keys"
    probe.mkdir(mode=0o700)
    subprocess.run(["env", "-i", "PATH=/usr/bin:/bin", "GALAXYBRIDGE_ADB_USER_DIR=" + str(probe.resolve()),
                    str(result / "Contents/Resources/platform-tools/adb"), "version"],
                   check=True, stdout=subprocess.DEVNULL)
    dmg = output / "GalaxyBridge-0.1.0-macOS-arm64.dmg"
    mounted = work / "mounted"
    mounted.mkdir()
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mounted), str(dmg)],
                   check=True, stdout=subprocess.DEVNULL)
    try:
        assert os.readlink(mounted / "Applications") == "/Applications"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(mounted / "Galaxy Bridge.app")], check=True)
        shutil.copytree(mounted / "Galaxy Bridge.app", work / "Test Applications/Galaxy Bridge.app", symlinks=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(work / "Test Applications/Galaxy Bridge.app")], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", str(mounted)], check=True, stdout=subprocess.DEVNULL)
    assert subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    nested = [sys.executable, str(ROOT / "scripts/package-macos-direct.py"), str(app), str(app / "nested")]
    assert subprocess.run(nested, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    # A hash failure must stop before any app or DMG output is created.
    damaged_runtime = work / "bad-adb"
    shutil.copytree(runtime, damaged_runtime)
    with (damaged_runtime / "adb").open("ab") as file:
        file.write(b"tampered")
    failure_output = work / "bad-candidate"
    damaged = [sys.executable, str(ROOT / "scripts/package-macos-direct.py"), str(app), str(failure_output),
               "--adb-runtime", str(damaged_runtime)]
    assert subprocess.run(damaged, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
    assert not failure_output.exists()
print("Direct package: real adb/dependency closure, ad-hoc signatures, DMG mount/copy, no-clobber and tamper rejection passed.")
print("Fixture host only exits: this does not validate Galaxy Bridge launch, pairing, or Camera Extension activation.")
