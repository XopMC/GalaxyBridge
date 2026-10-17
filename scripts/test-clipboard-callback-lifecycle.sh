#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-clipboard-callbacks.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,sys
root,tmp=map(Path,sys.argv[1:])
source=Path(os.environ.get('GB_CLIPBOARD_AGENT_SOURCE',root/'third_party/scrcpy-gb-sync/ClipboardAgent.java')).read_text()
start=source.index('    public static void main(')
end=source.index('    private static void run(String socketName,',start)
fixture=(root/'tests/java/com/genymobile/scrcpy/ClipboardCallbackLifecycleSpec.java').read_text()
(tmp/'ClipboardCallbackLifecycleSpec.java').write_text(fixture.replace('    // ACTUAL_ENTRYPOINT_AND_CALLBACK_LIFETIME',source[start:end]))
(tmp/'RunClipboardCallbacks.java').write_text('public class RunClipboardCallbacks { public static void main(String[] args) throws Exception { com.genymobile.scrcpy.ClipboardCallbackLifecycleSpec.test(); }}')
PY
source "$root/scripts/select-java-runtime.sh"
gb_clipboard_java=$(galaxybridge_select_java_home)
"$gb_clipboard_java/bin/javac" -d "$tmp" "$root/third_party/scrcpy-gb-sync/ClipboardSnapshotCache.java" "$tmp/ClipboardCallbackLifecycleSpec.java" "$tmp/RunClipboardCallbacks.java"
"$gb_clipboard_java/bin/java" -ea -cp "$tmp" RunClipboardCallbacks
