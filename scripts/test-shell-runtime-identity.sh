#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-shell-identity.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/Transport/ShellCapabilityBridgeProvider.swift').read_text()
def member(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{': depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0: return source[start:end + 1]
    raise AssertionError(signature)
fixture = (root / 'macos/GalaxyBridgeMacTests/ShellRuntimeIdentitySpec.swift').read_text()
for marker, signature in [('VERIFIED_RUNTIME', 'var currentRuntimeVerified:'),
                          ('IDENTITY_PREDICATE', 'var needsRuntimeUpgrade:'),
                          ('RECOVERY_ADMISSION', 'private var canRecoverUnavailableRuntime:'),
                          ('SAFE_UPGRADE', 'var canUpgradeRuntimeSafely:'),
                          ('BEGIN_UPGRADE', 'func beginRuntimeUpgrade()'),
                          ('END_UPGRADE', 'func endRuntimeUpgrade()'),
                          ('NOTIFY_IDLE', 'private func notifyRuntimeUpgradeIfIdle()'),
                          ('RESERVE_ADMISSION', 'private func reserveLeaseAdmission('),
                          ('RESULT_ADMISSION', 'func receive(_ result:'),
                          ('DISCONNECT', 'func disconnected(authenticatedSessionID:')]:
    fixture = fixture.replace('// ACTUAL_' + marker, member(signature))
def prefix(signature, before):
    start = source.index(signature)
    opening = source.index('{', start)
    return source[opening + 1:source.index(before, opening)]
fixture = fixture.replace('// ACTUAL_COLD_CAPTURE', prefix('func prepare(configuration:', '        var committed = false'))
fixture = fixture.replace('// ACTUAL_COLD_PANEL', prefix('func beginPanelOwnership(', '        let owner = ShellCapabilityBridgeLease'))
fixture = fixture.replace('// ACTUAL_ADMITTED_REFRESH', member('private func refreshAdmittedRuntime(') if 'private func refreshAdmittedRuntime(' in source else '')
(out / 'ActualIdentity.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualIdentity.swift" -o "$tmp/spec"
"$tmp/spec"
