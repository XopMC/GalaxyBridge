#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-prepared-shell-selection.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,re,sys
root,out=map(Path,sys.argv[1:])
source=Path(os.environ.get('GB_PREPARED_SHELL_MODEL_SOURCE',root/'macos/GalaxyBridgeMac/AppModel.swift')).read_text()
windows=(root/'macos/GalaxyBridgeMac/ApplicationWindowCoordinator.swift').read_text()
def method(text,marker):
 start=text.index(marker);opening=text.index('{',start);depth=0
 for end in range(opening,len(text)):
  if text[end]=='{':depth+=1
  elif text[end]=='}':
   depth-=1
   if depth==0:return text[start:end+1].replace('private func','func',1)
 raise RuntimeError(marker)
fixture=(root/'macos/GalaxyBridgeMacTests/PreparedShellSelectionSpec.swift').read_text()
fixture=fixture.replace('// ACTUAL_PREPARED_SHELL_POLICY',method(source,'    private func activeShellProvider('))
fixture=fixture.replace('// ACTUAL_AVAILABLE_SHELL_POLICY',method(source,'    private func availableShellProvider('))
fixture=fixture.replace('// ACTUAL_SHELL_OWNER_LOOKUP',method(source,'    private func shellProviderForOwner('))
fixture=fixture.replace('// ACTUAL_ENHANCED_CAPTURE_ROUTE',method(source,'    func enhancedCaptureRoute('))
fixture=fixture.replace('// ACTUAL_CONTINUING_ROUTE',method(source,'    private func enhancedContinuingRouteSerial('))
fixture=fixture.replace('// ACTUAL_QUIC_SELECTION',method(source,'    func quicWirelessSelection('))
recovery=method(source,'    private func reconcileEnhancedPrimaryRoutes(')
gate=re.search(r'else if (session.serial.hasPrefix\("shell:"\)[^{]+)\{\s*session.retryOwnedCleanup\(\)', recovery)
assert gate, 'Missing actual shell retirement retry branch'
fixture=fixture.replace('// ACTUAL_SHELL_RETIREMENT_GATE','if '+gate.group(1)+'{ return true }; return false')
marker='    func hasOwnedADBCaptureWindows('
query=method(windows,marker) if marker in windows else 'func hasOwnedADBCaptureWindows(deviceID: String) -> Bool { false }'
fixture=fixture.replace('// ACTUAL_OWNED_SESSIONS',method(windows,'    private func ownedSessions('))
fixture=fixture.replace('// ACTUAL_OWNED_APP_QUERY',query)
fixture=fixture.replace('// ACTUAL_OWNED_SHELL_APP_QUERY',method(windows,'    func hasOwnedShellCaptureWindows('))
(out/'ActualPreparedShellSelection.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualPreparedShellSelection.swift" -o "$tmp/spec"
"$tmp/spec"
swiftc -swift-version 6 -parse-as-library -DGB_INPUT_REPLAY_QA \
    "$tmp/ActualPreparedShellSelection.swift" \
    "$root/macos/GalaxyBridgeMac/Media/PrimaryMediaDiagnostics.swift" \
    "$root/macos/GalaxyBridgeMac/Media/PrimaryTouchReplay.swift" \
    -framework CoreVideo -o "$tmp/qa-spec"
"$tmp/qa-spec" --primary-media-diagnostics --primary-input-marker-nonce=270544960 \
    --qa-touch-replay-peer=device:qa-peer --qa-replay-quic
