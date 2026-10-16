#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-preparation.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
# Execute the actual AppModel entry point with inert ADB, transport and owner
# boundaries. A test-side copy of its branching could hide the regression.
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/AppModel.swift').read_text()
start = source.index('    private func prepareNearbyConnection(deviceID: String, automatic: Bool, connectAfterPreparation: Bool = true)')
end = source.index('\n    private func reconcileShellCapabilities()', start)
fixture = (root / 'macos/GalaxyBridgeMacTests/NearbyPreparationSpec.swift').read_text()
(temp / 'ActualNearbyPreparation.swift').write_text(fixture.replace('    // ACTUAL_NEARBY_PREPARATION', source[start:end]))
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualNearbyPreparation.swift" -o "$tmp/spec"
"$tmp/spec"
