#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-primary-copy.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/PrimaryCopyResourceSpec.swift" \
    -o "$GB_TMP/PrimaryCopyResourceSpec"

"$GB_TMP/PrimaryCopyResourceSpec" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Resources/en.lproj/Localizable.strings" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Resources/ru.lproj/Localizable.strings"
