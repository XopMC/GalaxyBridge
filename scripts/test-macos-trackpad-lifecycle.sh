#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-trackpad-lifecycle.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,sys
root,out=map(Path,sys.argv[1:])
source=Path(os.environ.get('GB_TRACKPAD_INPUT_SOURCE',root/'macos/GalaxyBridgeMac/DeviceInputSurface.swift')).read_text()
def declaration(marker):
    start=source.index(marker)
    opening=source.index('{',start)
    depth=0
    for end in range(opening,len(source)):
        if source[end]=='{':depth+=1
        elif source[end]=='}':
            depth-=1
            if depth==0:return source[start:end+1]
    raise RuntimeError('Unclosed actual declaration: '+marker)
methods=[declaration('    override func scrollWheel(').replace('override func','func',1)]
for name in ['finishTrackpadGesture','deliverTouch','scheduleTrackpadRelease']:
    methods.append(declaration('    private func '+name+'(').replace('private func','func',1))
fixture=(root/'macos/GalaxyBridgeMacTests/TrackpadGestureLifecycleSpec.swift').read_text()
fixture=fixture.replace('// ACTUAL_MOTION_FILTER',declaration('struct TrackpadMotionFilter {'))
fixture=fixture.replace('// ACTUAL_TRACKPAD_METHODS','\n'.join(methods))
(out/'ActualTrackpadLifecycle.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualTrackpadLifecycle.swift" -o "$tmp/spec"
"$tmp/spec"
