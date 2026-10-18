#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-display-interaction.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateControllerProtocol.swift" \
  "$root/macos/GalaxyBridgeMac/PhoneDisplayInteractionCoordinator.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/ScrcpyDisplayInteractionLease.swift" \
  "$root/macos/GalaxyBridgeMacTests/PhoneDisplayInteractionSpec.swift" -o "$tmp/spec"
"$tmp/spec"
