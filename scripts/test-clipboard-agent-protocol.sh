#!/usr/bin/env bash
set -euo pipefail
gb_root=$(cd "$(dirname "$0")/.." && pwd)
gb_tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-clipboard-protocol.XXXXXX")
trap 'rm -rf -- "$gb_tmp"' EXIT
xcrun swiftc "$gb_root/Sources/GalaxyBridgeEnhancedCore/ScrcpyDeviceMessage.swift" \
    "$gb_root/macos/GalaxyBridgeMacTests/ClipboardAgentProtocolSpec.swift" -o "$gb_tmp/spec"
"$gb_tmp/spec"
