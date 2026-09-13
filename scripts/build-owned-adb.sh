#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GB_WORK="${GB_OWNED_ADB_BUILD_ROOT:-$GB_ROOT/.build/owned-adb}"
GB_SOURCE="$GB_WORK/source"
GB_BUILD="$GB_WORK/build-macos14"
GB_OUTPUT="${1:-$GB_WORK/runtime-v2.2}"
GB_ARCHIVE="${GB_ADB_SOURCE_ARCHIVE:-$GB_WORK/source.tar.gz}"
GB_SHA=6aff0c12aa8d22f3621845fb2dd7e1fb874546761376f9791312c4939cab38e6
[[ ! -e "$GB_OUTPUT" ]] || { echo 'Owned runtime output exists; use a new path.' >&2; exit 2; }
if [[ ! -f "$GB_ARCHIVE" ]]; then
  mkdir -p "$(dirname "$GB_ARCHIVE")"
  curl --fail --location --retry 3 \
    https://github.com/meator/android-tools-static/releases/download/36.0.1/android-tools-static-36.0.1-src.tar.gz \
    -o "$GB_ARCHIVE.part"
  [[ "$(shasum -a 256 "$GB_ARCHIVE.part" | cut -d ' ' -f 1)" == "$GB_SHA" ]] || exit 2
  mv "$GB_ARCHIVE.part" "$GB_ARCHIVE"
fi
[[ "$(shasum -a 256 "$GB_ARCHIVE" | cut -d ' ' -f 1)" == "$GB_SHA" ]] || exit 2
mkdir -p "$GB_WORK"
if [[ ! -d "$GB_SOURCE" ]]; then
  tar -xzf "$GB_ARCHIVE" -C "$GB_WORK"
  mv "$GB_WORK/android-tools-static-36.0.1-src" "$GB_SOURCE"
fi
gb_patch() {
  local patch_file="$1"
  if patch -d "$GB_SOURCE" -p1 --dry-run --forward < "$patch_file" >/dev/null 2>&1; then
    patch -d "$GB_SOURCE" -p1 --forward < "$patch_file"
  elif ! patch -d "$GB_SOURCE" -p1 --dry-run --reverse < "$patch_file" >/dev/null 2>&1; then
    echo "Source does not match owned patch: $patch_file" >&2; exit 2
  fi
}
# Patch 1 precedes dependency setup. Patch 2 also modifies the downloaded LGPL
# dependency, so its complete matching sources are materialized by Meson first.
if ! grep -q 'Galaxy Bridge owned-runtime contract v1' "$GB_SOURCE/vendor/adb/adb_utils.cpp"; then
  gb_patch "$GB_ROOT/third_party/adb-owned/patches/0001-owned-runtime.patch"
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
if [[ ! -f "$GB_BUILD/build.ninja" ]]; then
  meson setup "$GB_BUILD" "$GB_SOURCE" --buildtype=release \
    --default-library=static --wrap-mode=forcefallback -Dlibusb:default_library=shared -Dgenerate_manpages=disabled \
    -Dc_args=-mmacosx-version-min=14.0 -Dcpp_args=-mmacosx-version-min=14.0 \
    -Dc_link_args=-mmacosx-version-min=14.0 -Dcpp_link_args=-mmacosx-version-min=14.0
fi
gb_patch "$GB_ROOT/third_party/adb-owned/patches/0002-nonseizing-usb.patch"
gb_patch "$GB_ROOT/third_party/adb-owned/patches/0003-private-socket-backlog.patch"
meson compile -C "$GB_BUILD" ./vendor/adb:executable -j "${GB_BUILD_JOBS:-4}"
python3 "$GB_ROOT/scripts/verify-adb-deployment-target.py" "$GB_BUILD"
python3 "$GB_ROOT/scripts/test-owned-adb-usb-policy.py" "$GB_SOURCE/subprojects/libusb-1.0.29/libusb/os/galaxybridge_usb_policy.h"
python3 "$GB_ROOT/scripts/stage-redistributable-adb.py" "$GB_SOURCE" "$GB_BUILD" "$GB_OUTPUT"
python3 "$GB_ROOT/scripts/test-owned-adb-artifact.py" "$GB_OUTPUT/adb" --write-contract
python3 - "$GB_OUTPUT" <<'PY'
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
root.joinpath('SHA256SUMS').write_text(''.join(
    hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + str(path.relative_to(root)) + '\n'
    for path in sorted(root.rglob('*')) if path.is_file() and path.name != 'SHA256SUMS'))
PY
