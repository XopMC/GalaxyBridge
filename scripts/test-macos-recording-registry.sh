#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-recording-registry.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc "$GB_ROOT/macos/GalaxyBridgeMac/RecordingRegistry.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/RecordingRegistrySpec.swift" -o "$GB_TMP/spec"
"$GB_TMP/spec"
