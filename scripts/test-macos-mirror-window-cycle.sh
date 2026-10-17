#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-mirror-cycle.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,sys
root,out=map(Path,sys.argv[1:])
presenter=Path(os.environ.get('GB_CYCLE_PRESENTER_SOURCE',root/'macos/GalaxyBridgeMac/DeviceMirrorWindowPresenter.swift')).read_text()
view=(root/'macos/GalaxyBridgeMac/DeviceMirrorWindow.swift').read_text()
geometry=(root/'macos/GalaxyBridgeMac/MirrorWindowGeometry.swift').read_text()
def decl(source,marker):
 start=source.index(marker);opening=source.index('{',start);depth=0
 for end in range(opening,len(source)):
  if source[end]=='{':depth+=1
  elif source[end]=='}':
   depth-=1
   if depth==0:return source[start:end+1]
 raise RuntimeError(marker)
def assignment(source,scope,marker):
 start=source.index(marker,source.index(scope));end=source.index('\n',start)
 while source[start:end].count('(')!=source[start:end].count(')'):end=source.index('\n',end+1)
 return source[start:end]
fixture=(root/'macos/GalaxyBridgeMacTests/MirrorWindowCycleSpec.swift').read_text()
policy=decl(presenter,'enum MirrorWindowCyclePolicy {') if 'enum MirrorWindowCyclePolicy {' in presenter else ''
fixture=fixture.replace('// ACTUAL_CYCLE_POLICY',policy+'\n'+decl(geometry,'enum MirrorWindowPinPolicy {'))
fixture=fixture.replace('// ACTUAL_PRESENTER_METHODS','\n'.join(decl(presenter,'    func '+name+'(') for name in ['registerPrimaryWindow','windowWillClose']))
fixture=fixture.replace('// ACTUAL_PIN_METHODS','\n'.join(decl(view,'        func '+name+'(') for name in ['captureBaseCollectionBehavior','updatePinPolicy']))
fixture=fixture.replace('// ACTUAL_HEADER_ASSIGNMENT','\n'.join(assignment(view,'        func updateHeader(',key) for key in ['panel.collectionBehavior =','panel.isExcludedFromWindowsMenu =']))
fixture=fixture.replace('// ACTUAL_RESIZE_ASSIGNMENT','\n'.join(assignment(view,'        func updateResizePanels(',key) for key in ['panel.collectionBehavior =','panel.isExcludedFromWindowsMenu =']))
(out/'ActualMirrorWindowCycle.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualMirrorWindowCycle.swift" -o "$tmp/spec"
"$tmp/spec"
