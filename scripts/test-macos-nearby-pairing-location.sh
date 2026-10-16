#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-pairing-location.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'CHECK'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/Transport/NearbyConnectionCoordinator.swift').read_text()
def method(header):
    start = source.index(header)
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
for header in ['    func startDiscovery()', '    private func pumpDiscoveryProbe()']:
    assert 'requestWhenInUseAuthorization' not in method(header), 'Passive discovery must never request Location'
fixture = (root / 'macos/GalaxyBridgeMacTests/NearbyPairingLocationSpec.swift').read_text()
helpers = ''
if '    private func updateLocationPermissionHint()' in source:
    helpers = method('    private func updateLocationPermissionHint()') + '\n' + method('    func locationManagerDidChangeAuthorization(')
    fixture = fixture.replace('/* SIMULATE_CALLBACK */', 'locationManagerDidChangeAuthorization(location)')
fixture = fixture.replace('    // ACTUAL_PERMISSION_HELPERS', helpers)
fixture = fixture.replace('    // ACTUAL_BEGIN_PAIRING', method('    func beginOfflinePairing('))
fixture = fixture.replace('    // ACTUAL_END_PAIRING', method('    func endOfflinePairing()'))
(temporary / 'ActualNearbyPairingLocation.swift').write_text(fixture)
CHECK
swiftc -swift-version 6 -parse-as-library "$root/macos/GalaxyBridgeMac/Transport/NearbyTransportPrimitives.swift" \
    "$tmp/ActualNearbyPairingLocation.swift" -o "$tmp/spec"
"$tmp/spec"
