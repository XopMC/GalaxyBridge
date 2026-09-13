#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-device-selection.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/DeviceSelectionResolver.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/DeviceSelectionResolverSpec.swift" \
    -o "$GB_TMP/DeviceSelectionResolverSpec"

"$GB_TMP/DeviceSelectionResolverSpec"
