#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-adb-companion-routing.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
  -emit-library \
  -emit-module \
  -module-name GalaxyBridgeCore \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBClientCoreStub.swift" \
  "$GB_ROOT/Sources/GalaxyBridgeCore/ADBDeviceParser.swift" \
  -o "$GB_TMP/libGalaxyBridgeCore.dylib"

xcrun swiftc \
  -emit-library \
  -emit-module \
  -module-name GalaxyBridgeEnhancedCore \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBClientEnhancedCoreStub.swift" \
  "$GB_ROOT/Sources/GalaxyBridgeEnhancedCore/ScrcpyApplicationCatalog.swift" \
  -o "$GB_TMP/libGalaxyBridgeEnhancedCore.dylib"

xcrun swiftc \
  -I "$GB_TMP" \
  -L "$GB_TMP" \
  -lGalaxyBridgeCore \
  -lGalaxyBridgeEnhancedCore \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBOwnedRuntime.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpyApplicationDisplayIdentity.swift" \
  "${GB_ADB_CLIENT_SOURCE:-$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBClient.swift}" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBCompanionRoutingSpec.swift" \
  -o "$GB_TMP/ADBCompanionRoutingSpec"

DYLD_LIBRARY_PATH="$GB_TMP" "$GB_TMP/ADBCompanionRoutingSpec"
