#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/galaxybridge-audio-timeline.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP_DIR"' EXIT

/usr/bin/xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/AudioPresentationTimeline.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/AudioPresentationTimelineSpec.swift" \
  -o "$GB_TMP_DIR/audio-timeline-spec"
"$GB_TMP_DIR/audio-timeline-spec"
