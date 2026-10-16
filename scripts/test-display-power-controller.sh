#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jdk=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
sdk=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
classes=${GB_SCRCPY_CLASS_DIR:-}
if [[ -z "$classes" ]]; then
  for candidate in "$root/out/macos-arm64-release/native-build/scrcpy"/source-build.*/4.1/classes/com/genymobile/scrcpy/ClipboardAgent.class; do
    if [[ -f "$candidate" ]]; then classes=${candidate%/com/genymobile/scrcpy/ClipboardAgent.class}; break; fi
  done
fi
[[ -n "$classes" ]] || { echo 'Set GB_SCRCPY_CLASS_DIR to cached pinned server classes' >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-display-power.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
platform="$sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}/android.jar"
lambda="$sdk/build-tools/${GB_ANDROID_BUILD_TOOLS:-37.0.0}/core-lambda-stubs.jar"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -bootclasspath "$platform" -cp "$classes:$lambda" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayPowerController.java"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$tmp:$platform:$classes" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayPowerControllerTest.java"
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayPowerControllerTest "$@"
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayPowerControllerTest wire > "$tmp/wire"
python3 - "$tmp/wire" <<'PY'
import json,re,sys
from pathlib import Path
lines=Path(sys.argv[1]).read_bytes().splitlines()
assert len(lines)==5
for line in lines:
    assert len(line)<4096
    value=json.loads(line)
    assert set(value)=={'version','pid','startTime','initial','current','ok','error'}
    assert value['version']==1 and value['pid']==123 and value['startTime']=='456'
    assert value['ok'] is True and value['error']==''
    for name in ['initial','current']:
        assert 1<=len(value[name])<=8
        assert len({item['id'] for item in value[name]})==len(value[name])
        for item in value[name]:
            assert set(item)=={'id','on'} and type(item['on']) is bool and re.fullmatch(r'0|[1-9][0-9]{0,19}',item['id'])
assert json.loads(lines[-1])['initial']==json.loads(lines[-1])['current']
print('PASS actual bounded physical controller JSON header/ack schema through independent JSON decoder')
PY
