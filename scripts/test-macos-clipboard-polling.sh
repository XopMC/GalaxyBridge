#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-clipboard-polling.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/Transport/ScrcpyClipboardSession.swift').read_text()
methods = []
for name in ['didBecomeReady', 'didBecomeAgentReady', 'startLegacyClipboardPolling', 'agentUnavailable', 'receiveAgent', 'setText']:
    start = source.find('    private func ' + name + '(')
    if start < 0: start = source.find('    func ' + name + '(')
    if start < 0: continue
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{': depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                methods.append(source[start:end + 1].replace('private func', 'func', 1))
                break
fixture = (root / 'macos/GalaxyBridgeMacTests/ClipboardPollingSpec.swift').read_text()
socket = (root / 'macos/GalaxyBridgeMac/Transport/ClipboardAgentSocket.swift').read_text()
start = socket.index('    private func consume(')
end = socket.index('\n    }', start) + len('\n    }')
fixture = fixture.replace('// ACTUAL_AGENT_INPUT_METHOD', socket[start:end].replace('private func', 'func', 1))
(out / 'ActualClipboardPolling.swift').write_text(fixture.replace('// ACTUAL_CLIPBOARD_METHODS', '\n'.join(methods)))
PY
swiftc -swift-version 6 -parse-as-library \
  "$root/Sources/GalaxyBridgeEnhancedCore/ScrcpyDeviceMessage.swift" \
  "$tmp/ActualClipboardPolling.swift" -o "$tmp/spec"
"$tmp/spec"
