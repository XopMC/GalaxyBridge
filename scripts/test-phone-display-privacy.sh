#!/bin/bash
set -euo pipefail
privacy_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
privacy_test_dir="$(mktemp -d /tmp/galaxybridge-privacy.XXXXXX)"
trap 'rm -rf "$privacy_test_dir"' EXIT
cd "$privacy_repo_root"
swiftc -swift-version 6 -emit-module -emit-library -module-name GalaxyBridgeCore \
  Sources/GalaxyBridgeCore/PhoneDisplayPrivacy.swift \
  -o "$privacy_test_dir/libGalaxyBridgeCore.dylib" \
  -emit-module-path "$privacy_test_dir/GalaxyBridgeCore.swiftmodule"
swiftc -swift-version 6 -I "$privacy_test_dir" -L "$privacy_test_dir" -lGalaxyBridgeCore \
  -Xlinker -rpath -Xlinker "$privacy_test_dir" -parse-as-library \
  macos/GalaxyBridgeMac/PhoneDisplayPrivacyCoordinator.swift \
  macos/GalaxyBridgeMacTests/PhoneDisplayPrivacySpec.swift -o "$privacy_test_dir/spec"
swiftc -swift-version 6 -I "$privacy_test_dir" -L "$privacy_test_dir" -lGalaxyBridgeCore \
  -Xlinker -rpath -Xlinker "$privacy_test_dir" -parse-as-library \
  macos/GalaxyBridgeMac/Transport/DisplayPowerControllerProtocol.swift \
  macos/GalaxyBridgeMac/Transport/DisplayPowerControllerProcess.swift \
  macos/GalaxyBridgeMacTests/DisplayPowerControllerProtocolSpec.swift -o "$privacy_test_dir/controller-spec"
"$privacy_test_dir/controller-spec"
"$privacy_test_dir/spec"
