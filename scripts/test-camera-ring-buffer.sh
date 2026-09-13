#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_OUTPUT="$GB_ROOT/.build/camera-ring-buffer-spec"

/usr/bin/xcrun swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraAppGroupIdentifier.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraRingBufferWriter.swift" \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtension/CameraFrameContinuity.swift" \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtension/CameraRingReader.swift" \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtensionTests/CameraRingBufferSpec.swift" \
  -framework CoreVideo \
  -framework VideoToolbox \
  -o "$GB_OUTPUT"

"$GB_OUTPUT"
