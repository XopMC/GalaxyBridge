#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-recording.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

/usr/bin/plutil -convert json -o - \
  "$GB_ROOT/macos/Entitlements/GalaxyBridge-AppStore.entitlements" |
  /usr/bin/jq -e '."com.apple.security.files.user-selected.read-write" == true' >/dev/null

xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/RecordingDestination.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/RecordingDestinationSpec.swift" \
  -o "$GB_TMP/RecordingDestinationInternalSpec"
"$GB_TMP/RecordingDestinationInternalSpec"

xcrun swiftc -D GALAXYBRIDGE_APP_STORE \
  "$GB_ROOT/macos/GalaxyBridgeMac/RecordingDestination.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/RecordingDestinationSpec.swift" \
  -o "$GB_TMP/RecordingDestinationAppStoreSpec"
"$GB_TMP/RecordingDestinationAppStoreSpec"
