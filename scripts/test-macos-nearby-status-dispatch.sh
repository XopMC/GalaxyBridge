#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-status.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/Transport/NearbyConnectionCoordinator.swift').read_text()
fixture = (root / 'macos/GalaxyBridgeMacTests/NearbyStatusDispatchSpec.swift').read_text()
start = source.index('        case let .directLinkStatus(status):', source.index('    private func receive(')) + len('        case let .directLinkStatus(status):\n')
end = source.index('        case let .directLinkDescriptor(descriptor):', start)
fixture = fixture.replace('        // ACTUAL_AUTHENTICATED_STATUS_BRANCH', source[start:end])
start = source.index('    private func fail(_ session: Session, code: String)')
end = source.index('\n    }', start) + len('\n    }')
fixture = fixture.replace('    // ACTUAL_SESSION_FAILURE', source[start:end])
start = source.index('        if let confirmation = session.confirmation {', source.index('    private func retire('))
end = source.index('\n        }', start) + len('\n        }')
fixture = fixture.replace('        // ACTUAL_CONFIRMATION_RETIREMENT', source[start:end])
(temporary / 'ActualStatusDispatch.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyTransportPrimitives.swift" \
  "$tmp/ActualStatusDispatch.swift" -o "$tmp/spec"
"$tmp/spec"
