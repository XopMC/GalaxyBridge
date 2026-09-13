#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-camera-publication.XXXXXX")"
trap 'rm -rf -- "$GB_TMP"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraAppGroupIdentifier.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraRingBufferWriter.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraLifecycle.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraPublication.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraControlCommand.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraFailureDelivery.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationTerminationCleanup.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/CameraPublicationSpec.swift" \
  -framework CoreVideo -framework VideoToolbox -o "$GB_TMP/spec"
"$GB_TMP/spec" "$GB_ROOT"
