#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-app-window-resize.XXXXXX")
trap 'rm -rf -- "$GB_TEST_DIR"' EXIT HUP INT TERM

set --
if [ -f "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowResize.swift" ]; then
  set -- "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowResize.swift"
fi
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete "$@" \
  -framework AppKit \
  -framework SwiftUI \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ApplicationWindowResizeSpec.swift" \
  -o "$GB_TEST_DIR/ApplicationWindowResizeSpec"
"$GB_TEST_DIR/ApplicationWindowResizeSpec"
