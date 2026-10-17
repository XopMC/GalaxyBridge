#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-consent.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 "$root/Sources/GalaxyBridgeCore/NearbyBootstrapCrypto.swift" "$root/macos/GalaxyBridgeMacTests/NearbyConsentProofSpec.swift" -o "$tmp/spec"
"$tmp/spec"
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:])
s=(root/'macos/GalaxyBridgeMac/AppModel.swift').read_text()
a=s.index('    func beginNearbyPairing(candidateID:');b=s.index('\n    func connectNearby(',a)
f=(root/'macos/GalaxyBridgeMacTests/NearbyConsentEntrySpec.swift').read_text()
(tmp/'ActualConsentEntry.swift').write_text(f.replace('    // ACTUAL_ENTRY',s[a:b]))
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualConsentEntry.swift" -o "$tmp/entry"
"$tmp/entry"
