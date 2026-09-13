#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-enhanced-diagnostics-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/EnhancedSessionState.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/EnhancedSessionDiagnosticsSpec.swift" \
    -o "$GB_TMP/EnhancedSessionDiagnosticsSpec"

"$GB_TMP/EnhancedSessionDiagnosticsSpec"
