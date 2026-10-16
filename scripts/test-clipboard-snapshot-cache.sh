#!/usr/bin/env bash
set -euo pipefail
gb_root=$(cd "$(dirname "$0")/.." && pwd)
gb_java="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"
gb_tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-clipboard-cache.XXXXXX")
trap 'rm -rf -- "$gb_tmp"' EXIT
"$gb_java/bin/javac" -d "$gb_tmp" \
    "$gb_root/third_party/scrcpy-gb-sync/ClipboardSnapshotCache.java" \
    "$gb_root/third_party/scrcpy-gb-sync/ClipboardOriginTracker.java" \
    "$gb_root/tests/java/com/genymobile/scrcpy/ClipboardSnapshotCacheSpec.java"
"$gb_java/bin/java" -ea -cp "$gb_tmp" com.genymobile.scrcpy.ClipboardSnapshotCacheSpec
