#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-promotion.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/Transport/NearbyConnectionCoordinator.swift').read_text()
fixture = (root / 'macos/GalaxyBridgeMacTests/NearbyPairingPromotionSpec.swift').read_text()
start = source.index('    private func receivePairing(')
admission = source[source.index('\n', start) + 1:source.index('        if case let .pairingResponse', start)]
marker = '        } else if case let .pairingCommitAck(ack)? = envelope.payload {\n'
start = source.index(marker, start) + len(marker)
end = source.index('        } else { throw NearbyTransportFailure.frame }', start)
fixture = fixture.replace('        // ACTUAL_OFFER_ADMISSION', admission)
fixture = fixture.replace('        // ACTUAL_ACKNOWLEDGEMENT_BRANCH', source[start:end])
backend = (root / 'macos/GalaxyBridgeMacTests/PairedPeerStagingSpec.swift').read_text()
start = backend.index('final class MemoryPairedPeerBackend:')
end = backend.index('\n@main', start)
fixture = fixture.replace('// ACTUAL_MEMORY_BACKEND', backend[start:end])
(temporary / 'ActualNearbyPromotion.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library \
  "$root/Sources/GalaxyBridgeCore/PairingTranscript.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyTransportPrimitives.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/CompanionLifecycleEvents.swift" \
  "$root/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$root/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
  "$root/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift" \
  "$root/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift" \
  "$tmp/ActualNearbyPromotion.swift" -framework Security -framework LocalAuthentication -o "$tmp/spec"
"$tmp/spec"
