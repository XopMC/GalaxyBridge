#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-effective-capabilities.XXXXXX")
trap 'rm -rf -- "$GB_TEST_DIR"' EXIT HUP INT TERM
xcrun swiftc "$GB_ROOT/macos/GalaxyBridgeMac/EffectiveDeviceCapabilities.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/EffectiveDeviceCapabilitiesSpec.swift" \
    -o "$GB_TEST_DIR/EffectiveDeviceCapabilitiesSpec"
"$GB_TEST_DIR/EffectiveDeviceCapabilitiesSpec"
