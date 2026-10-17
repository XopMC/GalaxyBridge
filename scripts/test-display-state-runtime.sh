#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jdk=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
sdk=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
python3 - "$root/third_party/scrcpy-gb-sync/DisplayStateRuntimeBackend.java" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).is_file(), 'Missing real Android display-state backend and mutation completion fence'
PY
classes=${GB_SCRCPY_CLASS_DIR:-}
if [[ -z "$classes" ]]; then
  for candidate in "$root/out/macos-arm64-release/native-build/scrcpy"/source-build.*/4.1/classes/com/genymobile/scrcpy/ClipboardAgent.class; do
    if [[ -f "$candidate" ]]; then classes=${candidate%/com/genymobile/scrcpy/ClipboardAgent.class}; break; fi
  done
fi
[[ -n "$classes" ]] || { echo 'Set GB_SCRCPY_CLASS_DIR to cached pinned server classes' >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-display-runtime.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
platform="$sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}/android.jar"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -bootclasspath "$platform" -cp "$classes" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateSnapshot.java" "$root/third_party/scrcpy-gb-sync/DisplayStateOwnership.java" \
  "$root/third_party/scrcpy-gb-sync/DisplayStatePowerCalls.java" "$root/third_party/scrcpy-gb-sync/DisplayStateRuntimeBackend.java"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$tmp:$platform:$classes" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateRuntimeBackendTest.java"
"$jdk/bin/java" -ea -cp "$tmp:$platform:$classes" com.genymobile.scrcpy.DisplayStateRuntimeBackendTest
