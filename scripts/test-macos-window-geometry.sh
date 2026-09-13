#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-window-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework AppKit \
    "$GB_ROOT/macos/GalaxyBridgeMac/MirrorWindowGeometry.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/MirrorWindowGeometrySpec.swift" \
    -o "$GB_TMP/MirrorWindowGeometrySpec"

"$GB_TMP/MirrorWindowGeometrySpec"

if grep -q 'GALAXYBRIDGE_DEBUG_RESIZE_ZONES' \
    "$GB_ROOT/macos/GalaxyBridgeMac/DeviceMirrorWindow.swift"
then
    echo "Packaged mirror must not expose visible resize-zone debug controls" >&2
    exit 1
fi
