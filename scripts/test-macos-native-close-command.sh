#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-native-close.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework AppKit \
    "$GB_ROOT/macos/GalaxyBridgeMac/MirrorWindowGeometry.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/NativeCloseCommandSpec.swift" \
    -o "$GB_TMP/NativeCloseCommandSpec"

"$GB_TMP/NativeCloseCommandSpec"
