#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d /private/tmp/gb-owned-swift-build.XXXXXX)
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
GB_PINS="${GB_BUILD_PINS_DIRECTORY:?Run the CMake check target to generate compiled runtime pins.}"
case "$GB_PINS" in /*) ;; *) GB_PINS="$GB_ROOT/$GB_PINS";; esac
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeBuildPins \
  "$GB_PINS/BuildPins.swift" -o "$GB_TMP/libGalaxyBridgeBuildPins.dylib"
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeCore \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBClientCoreStub.swift" \
  "$GB_ROOT/Sources/GalaxyBridgeCore/ADBDeviceParser.swift" -o "$GB_TMP/libGalaxyBridgeCore.dylib"
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeEnhancedCore \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBClientEnhancedCoreStub.swift" \
  "$GB_ROOT/Sources/GalaxyBridgeEnhancedCore/ScrcpyApplicationCatalog.swift" -o "$GB_TMP/libGalaxyBridgeEnhancedCore.dylib"
xcrun swiftc -swift-version 6 -I "$GB_TMP" -L "$GB_TMP" -lGalaxyBridgeCore -lGalaxyBridgeEnhancedCore -lGalaxyBridgeBuildPins \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBOwnedRuntime.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpyApplicationDisplayIdentity.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBClient.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/WirelessADBService.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/WirelessADBReconnectPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBOwnedRuntimeSpec.swift" -o "$GB_TMP/spec"
GB_OWNED_ADB_TEST_RUNTIME="${GB_OWNED_ADB_TEST_RUNTIME:-$GB_ROOT/out/macos-arm64-release/artifacts/adb}" \
  DYLD_LIBRARY_PATH="$GB_TMP" "$GB_TMP/spec"
