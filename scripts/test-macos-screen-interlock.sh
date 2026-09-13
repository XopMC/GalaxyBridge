#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-screen-interlock-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    "$GB_ROOT/Sources/GalaxyBridgeCore/ScreenInterlock.swift" \
    "$GB_ROOT/Sources/GalaxyBridgeCore/ScreenStreamPlaceholder.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ScreenInterlockSpec.swift" \
    -o "$GB_TMP/ScreenInterlockSpec"

"$GB_TMP/ScreenInterlockSpec"

GB_BLACKOUT_BODY=$(awk '
  /private func applyInteractiveDisplayBlackout\(\)/ { capture = 1 }
  capture { print }
  /private func revealPhysicalDisplay\(\)/ { exit }
' "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpySession.swift")

printf '%s\n' "$GB_BLACKOUT_BODY" | grep -Fq 'adb.wakePhysicalDisplay(serial: serial)' || {
  echo "interactive blackout must wake an already sleeping Samsung after applying zero brightness" >&2
  exit 1
}
