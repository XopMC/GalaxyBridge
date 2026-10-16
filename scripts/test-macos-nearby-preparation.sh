#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-preparation.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
# Execute the actual AppModel entry point with inert ADB, transport and owner
# boundaries. A test-side copy of its branching could hide the regression.
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/AppModel.swift').read_text()
start = source.index('    private func prepareNearbyConnection(deviceID: String, automatic: Bool, connectAfterPreparation: Bool = true)')
end = source.index('\n    private func reconcileShellCapabilities()', start)
fixture = (root / 'macos/GalaxyBridgeMacTests/NearbyPreparationSpec.swift').read_text()
preference_start = source.index('    func setNearbyAutoConnect(')
preference_end = source.index('    private func reconnectNearbyIfIdle()', preference_start)
fixture = fixture.replace('    // ACTUAL_AUTOMATIC_PREFERENCE', source[preference_start:preference_end])
validation_start = source.find('    private func validateNearbyPreparation(')
validation = source[validation_start:start] if validation_start >= 0 else ''
fixture = fixture.replace('    // ACTUAL_PREPARATION_VALIDATION', validation)
reconcile_start = source.index('    private func reconcileShellCapabilities()')
reconcile_end = source.index('\n    }', reconcile_start) + len('\n    }')
readiness_start = source.index('    private func shellReadinessIsCurrent(')
readiness_storage_start = source.index('    private struct ShellReadinessPreparation {')
readiness_storage_end = source.index('\n', source.index('    private var shellReadinessTasks:', readiness_storage_start))
fixture = fixture.replace('    // ACTUAL_SHELL_READINESS_STORAGE', source[readiness_storage_start:readiness_storage_end].replace('private ', ''))
fixture = fixture.replace('    // ACTUAL_SHELL_READINESS', source[readiness_start:validation_start if validation_start >= 0 else start])
fixture = fixture.replace('    // ACTUAL_NEARBY_PREPARATION', source[start:end])
fixture = fixture.replace('    // ACTUAL_SHELL_RECONCILIATION', source[reconcile_start:reconcile_end])
storage = next(line for line in source.splitlines() if 'var nearbyPreparationTasks:' in line)
fixture = fixture.replace('    // ACTUAL_PREPARATION_TASK_STORAGE', storage.replace('private ', ''))
presentation_start = source.index('    func nearbyIsPreparing(deviceID:')
presentation_end = source.index('\n    }', presentation_start) + len('\n    }')
fixture = fixture.replace('    // ACTUAL_PREPARATION_PRESENTATION', source[presentation_start:presentation_end])
(temp / 'ActualNearbyPreparation.swift').write_text(fixture)
PY
swiftc -swift-version 6 -parse-as-library "$tmp/ActualNearbyPreparation.swift" -o "$tmp/spec"
"$tmp/spec"
