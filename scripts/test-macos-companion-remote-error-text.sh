#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-remote-error-text.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/CompanionRemoteErrorText.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/CompanionRemoteErrorTextSpec.swift" \
    -o "$GB_TMP/CompanionRemoteErrorTextSpec"
"$GB_TMP/CompanionRemoteErrorTextSpec" "$GB_ROOT"
