#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jdk=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
sdk=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
python3 - "$root/third_party/scrcpy-gb-sync/DisplayStateController.java" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).is_file(), 'Missing composite controller lifetime and typed v2 wire protocol'
PY
classes=${GB_SCRCPY_CLASS_DIR:-}
if [[ -z "$classes" ]]; then
  for candidate in "$root/out/macos-arm64-release/native-build/scrcpy"/source-build.*/4.1/classes/com/genymobile/scrcpy/ClipboardAgent.class; do
    if [[ -f "$candidate" ]]; then classes=${candidate%/com/genymobile/scrcpy/ClipboardAgent.class}; break; fi
  done
fi
[[ -n "$classes" ]] || { echo 'Set GB_SCRCPY_CLASS_DIR to cached pinned classes' >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-display-controller.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
platform="$sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}/android.jar"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -bootclasspath "$platform" -cp "$classes:$sdk/build-tools/${GB_ANDROID_BUILD_TOOLS:-37.0.0}/core-lambda-stubs.jar" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateSnapshot.java" "$root/third_party/scrcpy-gb-sync/DisplayStateOwnership.java" \
  "$root/third_party/scrcpy-gb-sync/DisplayStatePowerCalls.java" "$root/third_party/scrcpy-gb-sync/DisplayStateRuntimeBackend.java" \
  "$root/third_party/scrcpy-gb-sync/DisplayPowerController.java" \
  "$root/third_party/scrcpy-gb-sync/ShellCapabilityBridge.java" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateController.java"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$tmp:$platform:$classes" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateOwnershipTest.java" "$root/third_party/scrcpy-gb-sync/DisplayStateControllerTest.java"
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayStateControllerTest
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayStateControllerTest wire > "$tmp/wire.jsonl"
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayStateControllerTest wire-startup-failed > "$tmp/startup-failed.jsonl"
python3 - "$tmp/wire.jsonl" <<'PY'
import json,re,sys
from pathlib import Path
frames=[json.loads(line) for line in Path(sys.argv[1]).read_bytes().splitlines()]
assert [f['event'] for f in frames]==['ready','reply','reply','reply','reply','retired']
for f in frames:
 assert f['version']==2 and f['pid']==123 and f['startTime']=='456'
 assert f['ok'] is True and f['error']==''
 assert type(f['mutation_settled']) is bool
 assert len(json.dumps(f).encode())<=8192
 for name in ('initial','current'):
  s=f[name];assert type(s['defaultInteractive']) is bool and s['defaultWakefulness'] in ('AWAKE','ASLEEP','DREAMING','DOZING')
  assert s['transitionScope']=='GLOBAL' and 1<=len(s['panels'])<=8
  assert s['activeID'] in {p['id'] for p in s['panels']}
  assert len(s['panels'])==len({p['id'] for p in s['panels']})
  for p in s['panels']:assert p['mode'] in ('OFF','ON','DOZE','DOZE_SUSPEND','ON_SUSPEND') and re.fullmatch(r'0|[1-9][0-9]{0,19}',p['id'])
  for key in ('lastGlobalWakeTime','lastGlobalSleepTime','defaultActivityTime','defaultActivityNoChangeLightsTime'):assert re.fullmatch(r'0|[1-9][0-9]{0,18}',s[key])
final=frames[-1];assert final['state']=='RESTORED' and final['mutation_settled'] is True
assert final['current']['panels']==final['initial']['panels'] and final['current']['defaultInteractive']==final['initial']['defaultInteractive']
print('PASS actual v2 header/policy/status/terminal JSON independently decoded; exact raw-mode and scoped power evidence retained')
PY
xcrun swiftc -swift-version 6 \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateControllerProtocol.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateRetirementEvidence.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateLeaseState.swift" \
  "$root/macos/GalaxyBridgeMacTests/DisplayStateControllerProtocolSpec.swift" \
  -o "$tmp/swift-wire-spec"
"$tmp/swift-wire-spec" "$tmp/wire.jsonl" "$tmp/startup-failed.jsonl"
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
            if depth == 0: return source[start:end + 1].replace('private func ', 'func ', 1)
    raise AssertionError(signature)
fixture = (root / 'macos/GalaxyBridgeMacTests/CompositeDisplayProviderSpec.swift').read_text()
for marker, signature in [('BEGIN', 'func beginDisplayStateOwnership('), ('SNAPSHOT', 'func snapshotDisplayState('),
                          ('APPLY', 'func applyDisplayState('), ('VALIDATE', 'private func validateDisplayStateAdmission('),
                          ('POLL', 'func pollDisplayState('),
                          ('RETIRE', 'private func retireDisplayState(')]:
    fixture = fixture.replace('// ACTUAL_' + marker + '_DISPLAY_STATE', member(signature))
(out / 'CompositeDisplayProviderSpec.swift').write_text(fixture)
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateControllerProtocol.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateRetirementEvidence.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateLeaseState.swift" \
  "$tmp/CompositeDisplayProviderSpec.swift" -o "$tmp/swift-provider-spec"
"$tmp/swift-provider-spec" "$tmp/wire.jsonl"
python3 - "$tmp" <<'PY'
import json, sys
from pathlib import Path
directory = Path(sys.argv[1])
frames = [json.loads(line) for line in (directory / 'wire.jsonl').read_text().splitlines()]
failed = json.loads((directory / 'startup-failed.jsonl').read_text())
def literal(value):
    if value is None: return 'null'
    if type(value) is bool: return 'Boolean.TRUE' if value else 'Boolean.FALSE'
    if type(value) is int: return 'Long.valueOf("' + str(value) + '")'
    if type(value) is str: return json.dumps(value, ensure_ascii=True)
    if type(value) is list: return 'java.util.Arrays.<Object>asList(' + ','.join(map(literal, value)) + ')'
    if type(value) is dict:
        return 'fields(' + ','.join(literal(item) for pair in value.items() for item in pair) + ')'
    raise TypeError(type(value))
source = '''package com.genymobile.scrcpy;
import java.util.*;
public final class CompositeActualWireSpec {
 static Map<String,Object> fields(Object... values) {
  Map<String,Object> result = new HashMap<>();
  for (int i=0;i<values.length;i+=2) result.put((String)values[i],values[i+1]);
  return result;
 }
 public static void main(String[] args) {
  Map<String,Object>[] frames = new Map[]{FRAMES};
  ShellCapabilityBridge.CompositeReceipt header = ShellCapabilityBridge.CompositeReceipt.parse(frames[0]); header.header();
  for(int i=1;i<frames.length;i++) ShellCapabilityBridge.CompositeReceipt.parse(frames[i]).sameOwner(header);
  for(int i:new int[]{1,3,4}) {
   long revision = i==1?1:i==3?2:3; int mode = i==3?0:1;
   ShellCapabilityBridge.CompositeCommand command = ShellCapabilityBridge.CompositeCommand.parse(
     fields("action",2,"interactive",true,"panel_policy",mode,"revision",revision));
   ShellCapabilityBridge.CompositeReceipt.parse(frames[i]).policy(header,command);
  }
  ShellCapabilityBridge.CompositeReceipt.parse(frames[frames.length-1]).terminal(header,3,3);
  ShellCapabilityBridge.CompositeReceipt startup = ShellCapabilityBridge.CompositeReceipt.parse(FAILED);
  assert startup.event.equals("startup_failed") && startup.initial==null && startup.settled;
  try {startup.header(); throw new AssertionError("startup failure admitted");} catch(IllegalArgumentException expected){}
  System.out.println("PASS actual native v2 lifecycle and startup failure accepted by independent broker receipt validator");
 }
}
'''.replace('FRAMES', ','.join(map(literal, frames))).replace('FAILED', literal(failed))
(directory / 'CompositeActualWireSpec.java').write_text(source)
PY
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$tmp:$platform:$classes" \
  -d "$tmp" "$tmp/CompositeActualWireSpec.java"
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.CompositeActualWireSpec
