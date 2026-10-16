#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-connectivity-presentation.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/AppModel.swift').read_text()
def method(text, signature):
    start = text.index('    ' + signature)
    end = text.index('\n    }', start) + len('\n    }')
    return text[start:end]
methods = ['func nearbyIsPreparing(deviceID:', 'func nearbyConnectionHint(deviceID:',
           'func canConnectNearby(deviceID:', 'func internetSharingAvailabilityKey(deviceID:',
           'private func nearbyPairingCommitted()']
fixture = (root / 'macos/GalaxyBridgeMacTests/ConnectivityPresentationSpec.swift').read_text()
fixture = fixture.replace('    // ACTUAL_PRESENTATION_METHODS', '\n'.join(method(source, signature) for signature in methods))
nearby = (root / 'macos/GalaxyBridgeMac/Transport/NearbyConnectionCoordinator.swift').read_text()
fixture = fixture.replace('    // ACTUAL_CONNECTION_INTENT', method(nearby, 'func isConnectionRequested(deviceID:'))
(temporary / 'ActualPresentation.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library \
  "$root/macos/GalaxyBridgeMac/Transport/CompanionConnectivityCapabilities.swift" \
  "$tmp/ActualPresentation.swift" -o "$tmp/spec"
"$tmp/spec"
