#!/usr/bin/env python3
"""Run actual Mac proof/retirement paths without sockets, phone data or UI."""
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

provider = (ROOT / 'macos/GalaxyBridgeMac/Transport/ShellCapabilityBridgeProvider.swift').read_text()
session = (ROOT / 'macos/GalaxyBridgeMac/Transport/ScrcpySession.swift').read_text()
fixture = (ROOT / 'macos/GalaxyBridgeMacTests/CaptureAbsenceProofFlowSpec.swift').read_text()
fixture = fixture.replace('    // ACTUAL_PROVIDER_PROPERTIES', '\n'.join(block(provider, marker) for marker in [
    '    var needsRuntimeUpgrade:', '    var canUpgradeRuntimeSafely:']))
methods = '\n'.join(block(provider, marker).replace('private func ', 'func ', 1) for marker in [
    '    @discardableResult func refresh()', '    private func refreshAbsenceProofSupport()',
    '    func confirmADBCaptureAbsent(', '    func confirmDisplayControllerRetired(',
    '    func releaseRetiredControllerResource(', '    private func displayRetirementQuery(', '    private func verifiedRetirementResult('])
fixture = fixture.replace('    // ACTUAL_PROVIDER_METHODS', methods)
model = (ROOT / 'macos/GalaxyBridgeMac/AppModel.swift').read_text()
factory_methods = '\n'.join(block(model, marker).replace('private func ', 'func ', 1) for marker in [
    '    private func captureRetirementAuthority(', '    private func adoptCaptureRetirementIdentity(', '    func captureRetirementAbsenceProof('])
fixture = fixture.replace('    // ACTUAL_PROOF_FACTORIES', factory_methods)
fixture = fixture.replace('    // ACTUAL_REMOTE_RETIREMENT', block(session, '    private func retirePendingRemoteServers()').replace('private func ', 'func ', 1))
errors = block(provider, 'enum ShellCapabilityBridgeFailure:')
identity = block((ROOT / 'macos/GalaxyBridgeMac/Transport/DisplayPowerControllerProtocol.swift').read_text(), 'struct DisplayPowerControllerIdentity:')
with tempfile.TemporaryDirectory(prefix='gb-capture-proof-') as temporary:
    path = Path(temporary)
    (path / 'Actual.swift').write_text('import Foundation\n' + errors + '\n' + identity + '\n' + fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                    str(ROOT / 'macos/GalaxyBridgeMac/Transport/EnhancedSessionRouteHandoff.swift'),
                    str(ROOT / 'Sources/GalaxyBridgeCore/PhoneDisplayPrivacy.swift'),
                    str(path / 'Actual.swift'), '-o', str(path / 'spec')], check=True)
    subprocess.run([str(path / 'spec')], check=True, timeout=20)
