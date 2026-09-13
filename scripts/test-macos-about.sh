#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-about.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library \
    "$GB_ROOT/macos/GalaxyBridgeMac/AboutContent.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/AboutContentSpec.swift" \
    -o "$GB_TMP/AboutContentSpec"

"$GB_TMP/AboutContentSpec"
