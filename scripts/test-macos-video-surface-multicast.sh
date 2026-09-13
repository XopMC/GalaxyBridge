#!/bin/bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GB_TMP="$(mktemp -d)"
trap 'rm -rf "$GB_TMP"' EXIT

/usr/bin/swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/PrimaryMediaDiagnostics.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/VideoSurfacePresenterRegistry.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/VideoSurfacePresenterRegistrySpec.swift" \
  -o "$GB_TMP/VideoSurfacePresenterRegistrySpec"

"$GB_TMP/VideoSurfacePresenterRegistrySpec"
