#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-wireless-setup.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeCore \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBClientCoreStub.swift" \
    "$GB_ROOT/Sources/GalaxyBridgeCore/ADBDeviceParser.swift" -o "$GB_TMP/libGalaxyBridgeCore.dylib"
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeEnhancedCore \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ADBClientEnhancedCoreStub.swift" \
    "$GB_ROOT/Sources/GalaxyBridgeEnhancedCore/ScrcpyApplicationCatalog.swift" -o "$GB_TMP/libGalaxyBridgeEnhancedCore.dylib"
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeBuildPins \
    "$GB_ROOT/Sources/GalaxyBridgeBuildPins/BuildPins.swift" -o "$GB_TMP/libGalaxyBridgeBuildPins.dylib"
xcrun swiftc -swift-version 6 -I "$GB_TMP" -L "$GB_TMP" -lGalaxyBridgeCore -lGalaxyBridgeEnhancedCore -lGalaxyBridgeBuildPins \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBOwnedRuntime.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpyApplicationDisplayIdentity.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBClient.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/WirelessADBService.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/WirelessADBReconnectPolicy.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/WirelessADBSetupSpec.swift" -o "$GB_TMP/WirelessADBSetupSpec"
DYLD_LIBRARY_PATH="$GB_TMP" "$GB_TMP/WirelessADBSetupSpec"
xcrun swiftc -swift-version 6 -I "$GB_TMP" -L "$GB_TMP" -lGalaxyBridgeCore -lGalaxyBridgeEnhancedCore -lGalaxyBridgeBuildPins -framework Network \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBOwnedRuntime.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpyApplicationDisplayIdentity.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBClient.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/WirelessADBService.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/WirelessADBReconnectPolicy.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Setup/WirelessSetupCoordinator.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/WirelessSetupCoordinatorSpec.swift" -o "$GB_TMP/WirelessSetupCoordinatorSpec"
DYLD_LIBRARY_PATH="$GB_TMP" "$GB_TMP/WirelessSetupCoordinatorSpec"
