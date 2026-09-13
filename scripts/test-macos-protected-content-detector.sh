#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-protected-content-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework CoreVideo \
    "$GB_ROOT/macos/GalaxyBridgeMac/Media/ProtectedContentPixelDetector.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ProtectedContentPixelDetectorSpec.swift" \
    -o "$GB_TMP/ProtectedContentPixelDetectorSpec"

"$GB_TMP/ProtectedContentPixelDetectorSpec"
