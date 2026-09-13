#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-scrcpy-clipboard.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ScrcpyClipboardWiringSpec.swift" \
  -o "$GB_TMP/ScrcpyClipboardWiringSpec"

"$GB_TMP/ScrcpyClipboardWiringSpec" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpySession.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/AppModel.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowSession.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowCoordinator.swift"
