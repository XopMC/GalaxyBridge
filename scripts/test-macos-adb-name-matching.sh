#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-adb-name.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBDeviceNameMatching.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBDeviceNameMatchingSpec.swift" -o "$GB_TMP/NameSpec"
"$GB_TMP/NameSpec"
