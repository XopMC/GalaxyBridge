#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-native-primary-close.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework AppKit \
    "$GB_ROOT/macos/GalaxyBridgeMac/MirrorWindowGeometry.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/NativeCloseAllCommandRouter.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/NativePrimaryCloseCommandRouter.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/NativePrimaryCloseCommandRouterSpec.swift" \
    -o "$GB_TMP/NativePrimaryCloseCommandRouterSpec"

"$GB_TMP/NativePrimaryCloseCommandRouterSpec"
