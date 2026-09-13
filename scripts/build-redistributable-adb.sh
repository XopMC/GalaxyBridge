#!/usr/bin/env bash
# Build AOSP-derived adb without copying any Google SDK binary. The LGPL USB
# dependency remains replaceable and ships with its exact source/build files.
set -euo pipefail
GB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GB_WORK="${GB_ADB_BUILD_ROOT:-$GB_ROOT/.build/redistributable-adb}"
GB_OUT="${1:-$GB_ROOT/.build/redistributable-adb/runtime}"
GB_SOURCE="$GB_WORK/android-tools-static-36.0.1-src"
GB_SHA=6aff0c12aa8d22f3621845fb2dd7e1fb874546761376f9791312c4939cab38e6
mkdir -p "$GB_WORK"
if [[ ! -f "$GB_WORK/source.tar.gz" ]]; then
  curl --fail --location --retry 3 \
    https://github.com/meator/android-tools-static/releases/download/36.0.1/android-tools-static-36.0.1-src.tar.gz \
    -o "$GB_WORK/source.tar.gz.part"
  mv "$GB_WORK/source.tar.gz.part" "$GB_WORK/source.tar.gz"
fi
[[ "$(shasum -a 256 "$GB_WORK/source.tar.gz" | cut -d ' ' -f 1)" == "$GB_SHA" ]] || {
  echo 'Pinned source archive checksum failed.' >&2; exit 2;
}
[[ -d "$GB_SOURCE" ]] || tar -xzf "$GB_WORK/source.tar.gz" -C "$GB_WORK"
# Requirements exist only on the build Mac: Python, Meson 1.11.1, CMake, Ninja,
# Apple clang/SDK. --forcefallback uses hash-pinned Meson wraps instead of brew.
export MACOSX_DEPLOYMENT_TARGET=14.0
if [[ ! -f "$GB_WORK/build/build.ninja" ]]; then
  meson setup "$GB_WORK/build" "$GB_SOURCE" --buildtype=release \
    --default-library=static --wrap-mode=forcefallback \
    -Dlibusb:default_library=shared -Dgenerate_manpages=disabled
fi
meson compile -C "$GB_WORK/build" ./vendor/adb:executable -j "${GB_BUILD_JOBS:-4}"
python3 "$GB_ROOT/scripts/stage-redistributable-adb.py" "$GB_SOURCE" "$GB_WORK/build" "$GB_OUT"
