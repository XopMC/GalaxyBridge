#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jdk=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
sdk=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
source="$root/third_party/scrcpy-gb-sync/DisplayStateSnapshot.java"
python3 - "$source" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).is_file(), 'Missing exact display-state model; legacy Boolean panels cannot preserve AOD or distinguish global wakefulness'
PY
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-display-state.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
platform="$sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}/android.jar"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -bootclasspath "$platform" -d "$tmp" "$source"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$tmp" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateSnapshotTest.java"
"$jdk/bin/java" -ea -cp "$tmp" com.genymobile.scrcpy.DisplayStateSnapshotTest "$@"
