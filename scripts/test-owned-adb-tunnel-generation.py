#!/usr/bin/env python3
"""Exercise actual Helper forward ownership without devices, network or user data."""
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
    raise ValueError(marker)

model = (ROOT / 'macos/GalaxyBridgeMac/AppModel.swift').read_text()
coordinator_path = ROOT / 'macos/GalaxyBridgeMac/Transport/ADBCompanionTunnelCoordinator.swift'
coordinator = coordinator_path.read_text()
fixtures = ROOT / 'macos/GalaxyBridgeMacTests'
model_spec = (fixtures / 'CompanionTunnelGenerationSpec.swift').read_text().replace(
    '// ACTUAL', block(model, '    private func reconcileCompanionTunnels(').replace('private func ', 'func ', 1))
forward_spec = (fixtures / 'OwnedForwardGenerationSpec.swift').read_text().replace(
    '// TYPES', block(coordinator, 'enum ADBCompanionTunnelError:') + '\n' + block(coordinator, 'struct ADBCompanionTunnelResource:')).replace(
    '// METHOD', block(coordinator, '    private nonisolated static func allocateForward(').replace('private nonisolated static', 'static', 1))
with tempfile.TemporaryDirectory(prefix='gb-tunnel-generation-') as temporary:
    folder = Path(temporary)
    for name, source, dependencies in [
        ('model', model_spec, []), ('forward', forward_spec, []),
        ('quarantine', (fixtures / 'CompanionTunnelQuarantineGenerationSpec.swift').read_text(), [str(coordinator_path)])
    ]:
        path = folder / (name + '.swift')
        path.write_text(source)
        executable = folder / name
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                        *dependencies, str(path), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=15)
