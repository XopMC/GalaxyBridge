#!/bin/bash
set -euo pipefail
handoff_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
handoff_test_dir="$(mktemp -d /tmp/galaxybridge-route-handoff.XXXXXX)"
trap 'rm -rf "$handoff_test_dir"' EXIT
cd "$handoff_repo_root"
swiftc -swift-version 6 -parse-as-library \
  macos/GalaxyBridgeMac/Transport/EnhancedSessionRouteHandoff.swift \
  macos/GalaxyBridgeMac/PrimaryScreenDemandRegistry.swift \
  macos/GalaxyBridgeMacTests/EnhancedRouteHandoffSpec.swift -o "$handoff_test_dir/spec"
"$handoff_test_dir/spec"
