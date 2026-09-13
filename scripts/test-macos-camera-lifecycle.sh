#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-camera-lifecycle.XXXXXX")"
trap 'rm -rf -- "$GB_TMP"' EXIT
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name GalaxyBridgeCore \
  "$GB_ROOT/Sources/GalaxyBridgeCore/AnnexB.swift" \
  "$GB_ROOT/Sources/GalaxyBridgeCore/ScrcpyProtocol.swift" \
  "$GB_ROOT/Sources/GalaxyBridgeCore/MediaPacket.swift" \
  -emit-module-path "$GB_TMP/GalaxyBridgeCore.swiftmodule" -o "$GB_TMP/libGalaxyBridgeCore.dylib"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -I "$GB_TMP" -L "$GB_TMP" -lGalaxyBridgeCore \
  -Xlinker -rpath -Xlinker "$GB_TMP" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraAppGroupIdentifier.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraRingBufferWriter.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraLifecycle.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraPublication.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraControlCommand.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/MediaPlayoutClock.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/PrimaryMediaDiagnostics.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/NativeMediaAttempt.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/NativeMediaBuffer.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/VideoToolboxDecoder.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraVideoSession.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionLogicalSessionRecoverySupervisor.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/CameraStatusViewState.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/CameraLifecycleSpec.swift" \
  -framework CoreVideo -framework VideoToolbox -o "$GB_TMP/spec"
"$GB_TMP/spec"
