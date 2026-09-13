#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/galaxybridge-media-clock.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP_DIR"' EXIT

/usr/bin/xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/PrimaryMediaDiagnostics.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/MediaPlayoutClock.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/MediaPlayoutClockSpec.swift" \
  -o "$GB_TMP_DIR/media-clock-spec"
"$GB_TMP_DIR/media-clock-spec"
