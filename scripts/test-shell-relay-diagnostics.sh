#!/bin/sh
set -eu
relay_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
relay_temp=$(mktemp -d "${TMPDIR:-/tmp}/gb-relay-diagnostics.XXXXXX")
trap 'rm -rf -- "$relay_temp"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$relay_repo/macos/GalaxyBridgeMac/Transport/ShellRelayDiagnostics.swift" \
  "$relay_repo/macos/GalaxyBridgeMacTests/ShellRelayDiagnosticsSpec.swift" -o "$relay_temp/spec"
"$relay_temp/spec"

printf '' > "$relay_temp/Empty.swift"
xcrun swiftc -swift-version 6 -emit-module -module-name GalaxyBridgeProtocol "$relay_temp/Empty.swift" -emit-module-path "$relay_temp/GalaxyBridgeProtocol.swiftmodule"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -I "$relay_temp" \
  "$relay_repo/macos/GalaxyBridgeMac/Transport/ShellRelayDiagnostics.swift" \
  "$relay_repo/macos/GalaxyBridgeMac/Transport/ShellCapabilityBridgeRelay.swift" \
  "$relay_repo/macos/GalaxyBridgeMacTests/ShellRelayTimingFlowSpec.swift" -o "$relay_temp/flow-spec"
"$relay_temp/flow-spec"
