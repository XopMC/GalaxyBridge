#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-camera-status.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraLifecycle.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/CameraStatusViewState.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/CameraStatusViewStateSpec.swift" \
  -o "$GB_TMP/CameraStatusViewStateSpec"

"$GB_TMP/CameraStatusViewStateSpec"
