#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-text-input-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -emit-library \
    -emit-module \
    -module-name GalaxyBridgeCore \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/GalaxyBridgeCoreStub.swift" \
    -o "$GB_TMP/libGalaxyBridgeCore.dylib"

xcrun swiftc \
    -I "$GB_TMP" \
    -L "$GB_TMP" \
    -lGalaxyBridgeCore \
    -framework AppKit \
    -framework SwiftUI \
    "$GB_ROOT/macos/GalaxyBridgeMac/DeviceInputSurface.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Media/PrimaryMediaDiagnostics.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/DeviceTextInputSpec.swift" \
    -o "$GB_TMP/DeviceTextInputSpec"

DYLD_LIBRARY_PATH="$GB_TMP" "$GB_TMP/DeviceTextInputSpec"
