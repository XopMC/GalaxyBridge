#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-transport-interruption.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
import sys
from pathlib import Path
root, out = map(Path, sys.argv[1:])
source = (root/'macos/GalaxyBridgeMac/Transport/CompanionTLSClient.swift').read_text()
methods = []
for name in ['start', 'reportTransportInterruption', 'handleControlEnvelope', 'openChannel']:
    start = source.find('    func '+name+'(')
    if start < 0: start = source.find('    private func '+name+'(')
    if start < 0: continue
    opening = source.index('{',start); depth=0
    for end in range(opening, len(source)):
        if source[end]=='{': depth+=1
        elif source[end]=='}':
            depth-=1
            if depth==0:
                methods.append(source[start:end+1].replace('private func','func',1)); break
fixture=(root/'macos/GalaxyBridgeMacTests/CompanionTransportInterruptionSpec.swift').read_text()
(out/'ActualTransport.swift').write_text(fixture.replace('// ACTUAL_TRANSPORT_ENTRY_POINTS','\n'.join(methods)))
PY
xcrun swiftc -swift-version 6 -parse-as-library "$tmp/ActualTransport.swift" -o "$tmp/spec"
"$tmp/spec"
python3 - "$root" "$tmp" <<'PY'
import sys
from pathlib import Path
root,out=map(Path,sys.argv[1:])
def body(source, start):
    opening=source.index('{',start); depth=0
    for end in range(opening,len(source)):
        if source[end]=='{':depth+=1
        elif source[end]=='}':
            depth-=1
            if depth==0:return source[opening+1:end]
    raise ValueError('Unbalanced actual source')
tls=(root/'macos/GalaxyBridgeMac/Transport/CompanionTLSClient.swift').read_text()
enum='enum CompanionConnectionState: Equatable, Sendable {'+body(tls,tls.index('enum CompanionConnectionState:'))+'}'
provider=(root/'macos/GalaxyBridgeMac/Transport/ShellCapabilityBridgeProvider.swift').read_text()
start=provider.index('channelKind: .enhancedStream, stateHandler: { state in',provider.index('if let outputObserver, operation == .startScrcpy'))
callback=body(provider,start).removeprefix(' state in')
callback='func actualLogState(_ state: CompanionConnectionState, outputObserver: ScrcpyOwnedProcessOutputObserver) {'+callback+'}'
session=(root/'macos/GalaxyBridgeMac/Transport/ScrcpySession.swift').read_text()
start=session.index('    private func handleApplicationDisplayOutput(')
opening=session.index('{',start)
method=session[start:opening+1].replace('private func','func',1)+body(session,start)+'}'
fixture=(root/'macos/GalaxyBridgeMacTests/ShellLogInterruptionSpec.swift').read_text()
(out/'ActualLog.swift').write_text(enum+'\n'+fixture.replace('// ACTUAL_LOG_STATE_HANDLER',callback).replace('// ACTUAL_DISPLAY_EVENT_HANDLER',method))
PY
xcrun swiftc -swift-version 6 -parse-as-library "$root/macos/GalaxyBridgeMac/Transport/ScrcpyApplicationDisplayIdentity.swift" "$tmp/ActualLog.swift" -o "$tmp/log-spec"
"$tmp/log-spec"
