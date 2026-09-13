#!/usr/bin/env python3
"""Stage the source-built adb, dynamic libusb, notices and corresponding source."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import os
import tempfile
import tarfile

source, build, output = (Path(p).resolve() for p in sys.argv[1:])
if output.exists():
    raise SystemExit("ADB output already exists; choose another path.")
output.mkdir(parents=True)
shutil.copy2(build / "vendor/adb", output / "adb")
usb = build / "subprojects/libusb-1.0.29/libusb-1.0.0.dylib"
shutil.copy2(usb, output / usb.name)
def dependencies(path):
    return [line.strip().split(" (compatibility")[0]
            for line in subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
            if " (compatibility" in line]
for dependency in dependencies(output / "adb"):
    if "libusb" in dependency:
        subprocess.run(["install_name_tool", "-change", dependency,
                        "@executable_path/" + usb.name, str(output / "adb")], check=True)
subprocess.run(["install_name_tool", "-id", "@loader_path/" + usb.name, str(output / usb.name)], check=True)
for binary in (output / "adb", output / usb.name):
    bad = [d for d in dependencies(binary) if not d.startswith(("/usr/lib/", "/System/Library/", "@executable_path/", "@loader_path/"))]
    if bad:
        raise SystemExit("External runtime dependency: " + str(bad))
    subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", "-", str(binary)], check=True)
licenses = output / "licenses"
for path in source.rglob("*"):
    if path.is_file() and path.name.upper().startswith(("LICENSE", "NOTICE", "COPYING", "COPYRIGHT")):
        relative = path.relative_to(source)
        if "packagecache" in relative.parts:
            continue
        target = licenses / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
with tarfile.open(output / "libusb-1.0.29-source.tar.gz", "w:gz") as archive:
    archive.add(source / "subprojects/libusb-1.0.29", arcname="libusb-1.0.29")
(output / "NOTICE").write_text(
    "Galaxy Bridge bundles AOSP adb, source-built using android-tools-static 36.0.1.\n"
    "Upstream: https://github.com/meator/android-tools-static/tree/36.0.1\n"
    "Sources and pinned dependencies: scripts/build-redistributable-adb.sh in Galaxy Bridge.\n"
    "Copyright and full license notices are preserved in licenses/.\n"
    "libusb 1.0.29 is dynamically linked under LGPL-2.1-or-later. Its complete source,\n"
    "including Meson build files, is in libusb-1.0.29-source.tar.gz. You may modify\n"
    "or replace that library; no library-validation entitlement is enabled.\n"
    "Build replacement with meson setup build --default-library=shared; meson compile -C build.\n"
    "After replacement, re-sign the library and app ad-hoc with codesign --force --sign -.\n"
    "Reverse engineering for debugging modifications to this LGPL library is permitted.\n")
version_environment = None
owned_patch = Path(__file__).resolve().parents[1] / "third_party/adb-owned/patches/0001-owned-runtime.patch"
is_owned = "Galaxy Bridge owned-runtime contract v1" in (source / "vendor/adb/adb_utils.cpp").read_text()
with tempfile.TemporaryDirectory(prefix="gbadb-version-", dir="/private/tmp") as probe:
    if is_owned:
        version_environment = {"PATH": "/usr/bin:/bin", "GALAXYBRIDGE_ADB_USER_DIR": probe}
    version = subprocess.check_output([str(output / "adb"), "version"], text=True, env=version_environment)
provenance = {
    "source": "https://github.com/meator/android-tools-static/releases/download/36.0.1/android-tools-static-36.0.1-src.tar.gz",
    "source_sha256": "6aff0c12aa8d22f3621845fb2dd7e1fb874546761376f9791312c4939cab38e6",
    "build": "Apple clang; macOS 14 arm64; Meson; static dependencies except replaceable libusb",
    "adb_version": version,
    "staging_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
}
if is_owned:
    patches = sorted(owned_patch.parent.glob("*.patch"))
    provenance["patches_sha256"] = {patch.name: hashlib.sha256(patch.read_bytes()).hexdigest() for patch in patches}
    for patch in patches:
        shutil.copy2(patch, output / patch.name)
    with (output / "NOTICE").open("a") as notice:
        notice.write("Galaxy Bridge modifies ADB and libusb: owned key/socket/lifetime control and nonseizing USB.\n")
        notice.write("See bundled .patch files; exact modified libusb source is included in its source archive.\n")
    (output / "REPLACE-LIBUSB.txt").write_text(
        "Galaxy Bridge source builds compile expected runtime hashes into the host.\n"
        "To use a modified LGPL libusb, rebuild its included source and place the\n"
        "modified dylib in your source checkout's build artifacts/adb directory.\n"
        "Give it @loader_path/libusb-1.0.0.dylib as its install name and ad-hoc sign it.\n"
        "Run scripts/test-owned-adb-artifact.py on that directory's adb with\n"
        "--write-contract, then regenerate SHA256SUMS. Rebuild the host with\n"
        "python3 scripts/public-build.py macos-app --build-dir YOUR_BUILD_DIR.\n"
        "That compiles the replacement library hash into your new app; modifying\n"
        "only an adjacent manifest never changes executable trust. Repackage the\n"
        "new app with package-macos-direct.py and the same --adb-runtime directory.\n"
        "Full application/build source is provided in the Galaxy Bridge repository.\n"
        "No developer identity or private signing secret is required.\n")
(output / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
manifest = []
for path in sorted(output.rglob("*")):
    if path.is_file():
        manifest.append(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path.relative_to(output)))
(output / "SHA256SUMS").write_text("\n".join(manifest) + "\n")
print(f"Staged source-built standalone adb: {output}")
