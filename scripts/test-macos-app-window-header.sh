#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-app-header.XXXXXX")
trap 'rm -rf -- "$GB_TEST_DIR"' EXIT HUP INT TERM
set --
if [ -f "$GB_ROOT/macos/GalaxyBridgeMac/AppWindowHeaderVisibility.swift" ]; then
  set -- "$GB_ROOT/macos/GalaxyBridgeMac/AppWindowHeaderVisibility.swift"
fi
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete "$@" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/AppWindowHeaderVisibilitySpec.swift" \
  -o "$GB_TEST_DIR/AppWindowHeaderVisibilitySpec"
"$GB_TEST_DIR/AppWindowHeaderVisibilitySpec"
