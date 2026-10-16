#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-drawable-retry.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 \
  "$GB_ROOT/Sources/GalaxyBridgeCore/VideoSurfacePublicationState.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/VideoSurfaceDrawableRetrySpec.swift" \
  -o "$GB_TMP/spec"
"$GB_TMP/spec"
