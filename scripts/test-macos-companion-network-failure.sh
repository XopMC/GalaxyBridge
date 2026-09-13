#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-network-failure.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionNetworkFailure.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/CompanionNetworkFailureSpec.swift" \
  -o "$GB_TMP/spec"
"$GB_TMP/spec"
