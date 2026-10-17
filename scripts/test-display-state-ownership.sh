#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
jdk=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
sdk=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
python3 - "$root/third_party/scrcpy-gb-sync/DisplayStateOwnership.java" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).is_file(), 'Missing composite display owner: interactivity and physical panel privacy still have separate lifetimes'
PY
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-display-ownership.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
platform="$sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}/android.jar"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -bootclasspath "$platform" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateSnapshot.java" "$root/third_party/scrcpy-gb-sync/DisplayStateOwnership.java"
"$jdk/bin/javac" -source 8 -target 8 -Xlint:-options -cp "$tmp" -d "$tmp" \
  "$root/third_party/scrcpy-gb-sync/DisplayStateOwnershipTest.java"
"$jdk/bin/java" -ea -cp "$tmp" com.genymobile.scrcpy.DisplayStateOwnershipTest
