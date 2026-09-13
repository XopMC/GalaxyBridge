#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-termination-cleanup-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationTerminationCleanup.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ApplicationTerminationCleanupSpec.swift" \
    -o "$GB_TMP/ApplicationTerminationCleanupSpec"

"$GB_TMP/ApplicationTerminationCleanupSpec" "$GB_ROOT"
