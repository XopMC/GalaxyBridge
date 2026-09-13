#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_OUTPUT="$GB_ROOT/.build/camera-frame-continuity-spec"

/usr/bin/xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtension/CameraFrameContinuity.swift" \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtensionTests/CameraFrameContinuitySpec.swift" \
  -o "$GB_OUTPUT"

"$GB_OUTPUT"
