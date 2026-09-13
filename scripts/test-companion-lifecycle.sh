#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-companion-lifecycle.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework Combine \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/PairedPeerStub.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionLifecycleEvents.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionConnectionBootstrap.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionConnectingWatchdog.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionLogicalSessionRecoverySupervisor.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/CompanionLifecycleSpec.swift" \
    -o "$GB_TMP/CompanionLifecycleSpec"

"$GB_TMP/CompanionLifecycleSpec"

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionControlHeartbeat.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/CompanionControlHeartbeatSpec.swift" \
    -o "$GB_TMP/CompanionControlHeartbeatSpec"
"$GB_TMP/CompanionControlHeartbeatSpec"

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/WirelessADBReconnectPolicy.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/WirelessADBReconnectSpec.swift" \
    -o "$GB_TMP/WirelessADBReconnectSpec"
"$GB_TMP/WirelessADBReconnectSpec"
