#!/usr/bin/env python3
"""Execute actual coordinator/session retirement bodies without macOS UI or devices."""
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
    raise RuntimeError('Unclosed source block: ' + marker)

source = (ROOT / 'macos/GalaxyBridgeMac/ApplicationWindowCoordinator.swift').read_text()
session = (ROOT / 'macos/GalaxyBridgeMac/ApplicationWindowSession.swift').read_text()
fixture = (ROOT / 'macos/GalaxyBridgeMacTests/ApplicationRetirementOwnershipSpec.swift').read_text()
types = '\n'.join(block(source, marker).replace('private ', '') for marker in [
    '    struct RouteResume {', '    struct RouteSuspension {', '    private final class DeviceIdentity {', '    private struct Record {', '    private struct RetiringRecord {'])
storage = '\n'.join(line.replace('private ', '') for line in source.splitlines()
                    if any(('var ' + name + ':') in line for name in ['records', 'retiringRecords', 'retirementTasks', 'retirementTaskByKey', 'localSettlementTasks']))
methods = '\n'.join(block(source, marker).replace('private func ', 'func ', 1) for marker in [
    '    func adoptDeviceIdentity(', '    private func ownedSessions(', '    func captureSerials(', '    func hasRetiringOwners(',
    '    func hasStaleADBGeneration(', '    func hasOwnedADBCaptureWindows(', '    func hasOwnedShellCaptureWindows(',
    '    func windowWillClose(', '    @discardableResult\n    private func beginRetirement(', '    private func releaseRetiredRecord(',
    '    private func observeLateLocalSettlement(', '    func retryRetiringOwners(', '    func closeForFeaturePolicy(', '    func suspendForRouteChange(',
    '    func shutdownForApplicationTermination('])
fixture = fixture.replace('    // ACTUAL_TYPES_AND_STORAGE', types + '\n' + storage)
fixture = fixture.replace('    // ACTUAL_METHODS', methods)
fixture = fixture.replace('    // ACTUAL_SESSION_CLOSE', block(session, '    func close()') + '\n' + block(session, '    func closeAndWaitForCleanup()'))
with tempfile.TemporaryDirectory(prefix='gb-app-retirement-') as temporary:
    path = Path(temporary)
    (path / 'Actual.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                    str(path / 'Actual.swift'), '-o', str(path / 'spec')], check=True)
    subprocess.run([str(path / 'spec')], check=True, timeout=20)
