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
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -bootclasspath "$platform" -cp "$classes" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateSnapshot.java" "$root/third_party/scrcpy-gb-sync/DisplayStateOwnership.java" \
  "$root/third_party/scrcpy-gb-sync/DisplayStatePowerCalls.java" "$root/third_party/scrcpy-gb-sync/DisplayStateRuntimeBackend.java" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateController.java"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$tmp:$platform:$classes" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateOwnershipTest.java" "$root/third_party/scrcpy-gb-sync/DisplayStateControllerTest.java"
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayStateControllerTest
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayStateControllerTest wire > "$tmp/wire.jsonl"
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
