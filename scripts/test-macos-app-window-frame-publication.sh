#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-app-frame-publication.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
python3 - "$GB_ROOT" "$GB_TMP" <<'PYEXTRACT'
from pathlib import Path
import os, sys
root, output = map(Path, sys.argv[1:])
source = Path(os.environ.get('GB_APPLICATION_WINDOW_SESSION_SOURCE', root / 'macos/GalaxyBridgeMac/ApplicationWindowSession.swift')).read_text()
marker = 'scrcpy.ownedDecodedFrameHandler = '
start = source.index(marker) + len(marker)
opening = source.index('{', start)
depth = 0
for index in range(opening, len(source)):
    if source[index] == '{': depth += 1
    elif source[index] == '}':
        depth -= 1
        if depth == 0:
            body = source[start:index + 1]
            break
else:
    raise RuntimeError('Cannot locate actual decoded-frame handler')
preamble = 'import Combine\nimport CoreMedia\nimport CoreVideo\nimport Foundation\n@MainActor final class ApplicationWindowFrameProbe: ObservableObject {\n    @Published private(set) var aspectRatio: CGFloat = 16 / 9\n    let surface = FrameSurfaceProbe()\n    var closed = false\n    var receive: ((NativeDecodedFrame) -> Void)!\n    var presentationEvents = 0\n    init() { self.receive = '
(output / 'ApplicationWindowFrameProbe.swift').write_text(preamble + body + '\n    }\n    func handlePresentation(_ event: PresentationEvent) { presentationEvents += 1 }\n}\n')
PYEXTRACT
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -module-cache-path "$GB_TMP/modules" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowResize.swift" \
  "$GB_TMP/ApplicationWindowFrameProbe.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ApplicationWindowFramePublicationSpec.swift" \
  -o "$GB_TMP/ApplicationWindowFramePublicationSpec"
"$GB_TMP/ApplicationWindowFramePublicationSpec"
