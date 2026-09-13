#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-adb-runner.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBCommandRunnerSpec.swift" \
    -o "$GB_TMP/ADBCommandRunnerSpec"
"$GB_TMP/ADBCommandRunnerSpec"
