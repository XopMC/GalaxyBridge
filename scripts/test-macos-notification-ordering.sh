#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-notification-order.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,sys
root,tmp=map(Path,sys.argv[1:])
source=Path(os.environ.get('GB_APP_MODEL_SOURCE',root/'macos/GalaxyBridgeMac/AppModel.swift')).read_text()
a=source.index('struct BridgeNotificationActionRow:');b=source.index('struct BridgeSMSRow:',a)
models=source[a:b]
event=source.index('        case let .notificationEvent(event):')
a=source.index('                    at: 0\n                )\n',event)+len('                    at: 0\n                )\n')
marker='                rows = Array(rows.prefix(200))\n'
b=source.index(marker,a)+len(marker)
compaction=source[a:b]
a=source.index('    func notifications(for deviceID: String)')
b=source.index('\n    }',a)
presentation=next(line.strip() for line in source[a:b].splitlines() if line.strip().startswith('return rows.'))
fixture=(root/'macos/GalaxyBridgeMacTests/NotificationOrderingSpec.swift').read_text()
(tmp/'NotificationOrderingSpec.swift').write_text('import Foundation\n'+models+fixture.replace('        // ACTUAL_EVENT_COMPACTION',compaction).replace('        // ACTUAL_PRESENTATION_RETURN',presentation))
PY
xcrun swiftc -parse-as-library "$tmp/NotificationOrderingSpec.swift" -o "$tmp/spec"
"$tmp/spec"
