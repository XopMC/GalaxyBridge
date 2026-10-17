#!/usr/bin/env python3
"""Execute actual route recovery coordinator against deterministic ownership barriers; no devices or network."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{': depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0: return source[start:end + 1]
    raise RuntimeError(marker)
source = (ROOT / 'macos/GalaxyBridgeMac/AppModel.swift').read_text()
fixture = (ROOT / 'macos/GalaxyBridgeMacTests/CaptureRouteRecoverySpec.swift').read_text()
fields = ['captureRouteTransitionDevices','captureRouteHandoffTasks','captureRouteHandoffTickets','captureRoutePendingWindows',
          'captureRoutePeerKeys','captureRouteRetryTasks','captureRouteRetryTickets','captureRouteAttemptSignatures','captureRouteBackoffs']
storage = '\n'.join(line.replace('@Published ', '').replace('private ', '') for line in source.splitlines()
                    if any(('var ' + field + ':') in line or ('var ' + field + ' =') in line for field in fields))
methods = '\n'.join(block(source, marker).replace('private func ', 'func ', 1) for marker in [
    '    private func capturedRouteSerials(', '    private func handoffHelperID(', '    private func captureHandoffPlan(',
    '    private func validateCaptureHandoff(', '    private func settlePrimaryCaptureRetirements(',
    '    private func scheduleCaptureRouteRetry(', '    private func reconcileCaptureRouteHandoffs('])
fixture = fixture.replace('    // ACTUAL_STORAGE', storage).replace('    // ACTUAL_METHODS', methods)
fixture = fixture.replace('    // ACTUAL_PRIMARY_RELEASE', block(source, '    private func releasePhysicallySettledEnhancedRetirements()').replace('private func ', 'func ', 1))
with tempfile.TemporaryDirectory(prefix='gb-capture-recovery-') as temporary:
    path = Path(temporary); (path / 'Actual.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library',
                    str(ROOT / 'macos/GalaxyBridgeMac/Transport/EnhancedSessionRouteHandoff.swift'),
                    str(ROOT / 'Sources/GalaxyBridgeCore/ReconnectBackoff.swift'), str(path / 'Actual.swift'),
                    '-o',str(path / 'spec')],check=True)
    subprocess.run([str(path / 'spec')],check=True,timeout=20)
