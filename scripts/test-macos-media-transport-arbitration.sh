#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-media-arbitration.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/EnhancedSessionState.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Media/MediaTransportArbitration.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/MediaTransportArbitrationSpec.swift" \
    -o "$GB_TMP/MediaTransportArbitrationSpec"

"$GB_TMP/MediaTransportArbitrationSpec"
