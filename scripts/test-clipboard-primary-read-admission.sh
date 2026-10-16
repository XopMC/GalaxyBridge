#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-primary-read.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,sys
root,tmp=map(Path,sys.argv[1:])
source=Path(os.environ.get('GB_CLIPBOARD_AGENT_SOURCE',root/'third_party/scrcpy-gb-sync/ClipboardAgent.java')).read_text()
start=source.index('    private static Snapshot readSnapshot(')
end=source.index('    private static Method clipboardSourceMethod()',start)
fixture=(root/'tests/java/com/genymobile/scrcpy/ClipboardPrimaryReadAdmissionSpec.java').read_text()
(tmp/'ClipboardPrimaryReadAdmissionSpec.java').write_text(fixture.replace('    // ACTUAL_PRIMARY_READ_METHODS',source[start:end]))
PY
source "$root/scripts/select-java-runtime.sh"
gb_clipboard_java=$(galaxybridge_select_java_home)
"$gb_clipboard_java/bin/javac" -d "$tmp" "$root/third_party/scrcpy-gb-sync/ClipboardSnapshotCache.java" "$tmp/ClipboardPrimaryReadAdmissionSpec.java"
"$gb_clipboard_java/bin/java" -ea -cp "$tmp" com.genymobile.scrcpy.ClipboardPrimaryReadAdmissionSpec
