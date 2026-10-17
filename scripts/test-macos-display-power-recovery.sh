#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-panel-recovery.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 -emit-module -emit-library -module-name GalaxyBridgeCore "$root/Sources/GalaxyBridgeCore/PhoneDisplayPrivacy.swift" -o "$tmp/libGalaxyBridgeCore.dylib" -emit-module-path "$tmp/GalaxyBridgeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$tmp" -L "$tmp" -lGalaxyBridgeCore -Xlinker -rpath -Xlinker "$tmp" \
  "$root/macos/GalaxyBridgeMac/PhoneDisplayPrivacyCoordinator.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/PhonePrivacyServerOwnership.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayPowerControllerProtocol.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayPowerControllerProcess.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/ScrcpyDisplayPowerSession.swift" \
  "$root/macos/GalaxyBridgeMacTests/DisplayPowerOwnerRecoverySpec.swift" -o "$tmp/spec"
"$tmp/spec"
