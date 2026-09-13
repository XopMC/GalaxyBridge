#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-decoder.XXXXXX")"
trap 'rm -rf -- "$GB_TMP"' EXIT
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeCore \
  "$GB_ROOT/Sources/GalaxyBridgeCore/AnnexB.swift" \
  "$GB_ROOT/Sources/GalaxyBridgeCore/ScrcpyProtocol.swift" \
  -emit-module-path "$GB_TMP/GalaxyBridgeCore.swiftmodule" \
  -o "$GB_TMP/libGalaxyBridgeCore.dylib"
xcrun swiftc -I "$GB_TMP" -L "$GB_TMP" -lGalaxyBridgeCore \
  -Xlinker -rpath -Xlinker "$GB_TMP" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/MediaPlayoutClock.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/PrimaryMediaDiagnostics.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/NativeMediaAttempt.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/NativeMediaBuffer.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/VideoToolboxDecoder.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/VideoToolboxDecoderSpec.swift" \
  -o "$GB_TMP/decoder-spec"
"$GB_TMP/decoder-spec"
