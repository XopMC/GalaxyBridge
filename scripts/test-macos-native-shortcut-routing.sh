#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-native-shortcuts.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,sys
root,out=map(Path,sys.argv[1:])
source=Path(os.environ.get('GB_NATIVE_SHORTCUT_INPUT_SOURCE',root/'macos/GalaxyBridgeMac/DeviceInputSurface.swift')).read_text()
def method(marker):
 start=source.index(marker);opening=source.index('{',start);depth=0
 for end in range(opening,len(source)):
  if source[end]=='{':depth+=1
  elif source[end]=='}':
   depth-=1
   if depth==0:return source[start:end+1].replace('private func','func',1).replace('private static func','static func',1)
 raise RuntimeError('Missing body for '+marker)
methods=[method('    override func keyDown(')]
for marker in ['    func handlePreDispatchKeyEvent(', '    private func handlePreDispatchPrintableText(', '    private func handleCommandShortcut(', '    private static func androidKeycode(', '    private static func androidShortcutKeycode(', '    private static func androidMetaState(']:
 methods.append(method(marker))
fixture=(root/'macos/GalaxyBridgeMacTests/NativeShortcutRoutingSpec.swift').read_text()
(out/'ActualNativeShortcutRouting.swift').write_text(fixture.replace('// ACTUAL_SHORTCUT_METHODS','\n'.join(methods)))
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualNativeShortcutRouting.swift" -o "$tmp/spec"
"$tmp/spec"
