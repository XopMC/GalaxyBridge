#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-companion-diagnostics.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework Network \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionControlHeartbeat.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionConnectionDiagnostics.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionLogicalSessionRecoverySupervisor.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/CompanionConnectionDiagnosticsSpec.swift" \
    -o "$GB_TMP/CompanionConnectionDiagnosticsSpec"

"$GB_TMP/CompanionConnectionDiagnosticsSpec"
