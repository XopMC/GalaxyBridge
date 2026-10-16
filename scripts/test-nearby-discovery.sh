#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-discovery.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
temporary = Path(sys.argv[2])
source = (root / 'macos/GalaxyBridgeMac/Transport/NearbyConnectionCoordinator.swift').read_text()
assert '@Published private(set) var discoverySuggestions:' in source, 'passive discovery must publish untrusted suggestions'
android = (root / 'android/app/src/main/java/com/xopmc/galaxybridge/nearby/ForegroundConnectivityRuntime.kt').read_text()
assert 'getBoolean("nearby_enabled", true)' in android, 'foreground discovery must default on only after granted permissions'
start = source.index('    func startDiscovery() {')
end = source.index('\n    func connect(', start)
fixture = (root / 'macos/GalaxyBridgeMacTests/NearbyDefaultDiscoverySpec.swift').read_text()
cancel_start = source.index('    func cancelAutomaticConnection(deviceID: String)')
cancel_end = source.index('\n    private func hasVerifiedSharedOwner', cancel_start)
fixture = fixture.replace('    // ACTUAL_AUTOMATIC_CANCELLATION', source[cancel_start:cancel_end])
(temporary / 'ActualDiscoveryStartup.swift').write_text(fixture.replace('    // ACTUAL_DISCOVERY_START', source[start:end]))
print('PASS discovery publication and default opt-in contracts')
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualDiscoveryStartup.swift" -o "$tmp/startup-spec"
"$tmp/startup-spec"
swiftc -swift-version 6 "$root/macos/GalaxyBridgeMac/Transport/NearbyTransportPrimitives.swift" \
  "$root/macos/GalaxyBridgeMacTests/NearbyDiscoverySpec.swift" -o "$tmp/spec"
"$tmp/spec"
