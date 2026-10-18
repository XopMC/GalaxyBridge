#!/usr/bin/env python3
"""Compile bounded diagnostics and exercise actual STOP/status ownership bodies."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(os.environ.get('GB_MEDIA_DIAGNOSTIC_SOURCE_ROOT', Path(__file__).resolve().parents[1]))

def declaration(source, marker):
    text = source.read_text()
    start = text.index(marker); opening = text.index('{', start); depth = 0
    for end in range(opening, len(text)):
        if text[end] == '{': depth += 1
        elif text[end] == '}':
            depth -= 1
            if depth == 0: return text[start:end + 1]
    raise RuntimeError(marker)

with tempfile.TemporaryDirectory(prefix='gb-media-failure-diagnostics-') as temporary:
    output = Path(temporary)
    provider = ROOT / 'macos/GalaxyBridgeMac/Transport/ShellCapabilityBridgeProvider.swift'
    types = [
        (ROOT / 'macos/GalaxyBridgeMac/Media/NativeMediaAttempt.swift', 'enum NativeMediaFailure:'),
        (provider, 'enum ShellCapabilityBridgeFailure:'),
        (ROOT / 'macos/GalaxyBridgeMac/Transport/QuicBackendBridge.swift', 'struct QuicBackendError:'),
        (ROOT / 'Sources/GalaxyBridgeEnhancedCore/ScrcpyDeviceMessage.swift', 'public enum ScrcpyDeviceMessageError:'),
        (ROOT / 'macos/GalaxyBridgeMac/Transport/ScrcpySession.swift', 'enum ScrcpySessionError:'),
        (ROOT / 'macos/GalaxyBridgeMac/Transport/ScrcpySession.swift', 'enum ScrcpyReverseTunnelError:'),
        (ROOT / 'macos/GalaxyBridgeMac/Transport/ScrcpySession.swift', 'enum ScrcpyControlSocketError:'),
        (ROOT / 'macos/GalaxyBridgeMac/Transport/ADBClient.swift', 'enum ADBClientError:'),
    ]
    # Compile the real finite error declarations without the unrelated media/FFI owners.
    (output / 'FailureTypes.swift').write_text('import Foundation\n' + '\n'.join(declaration(*item) for item in types))
    helper = (ROOT / 'macos/GalaxyBridgeMac/Media/MediaFailureDiagnostics.swift').read_text()
    (output / 'Diagnostic.swift').write_text(helper.replace('import GalaxyBridgeEnhancedCore\n', ''))
    fixture = (ROOT / 'macos/GalaxyBridgeMacTests/MediaRetirementDiagnosticFlowSpec.swift').read_text()
    retirement = declaration(provider, '    func retire(_ lease: ShellCapabilityBridgeLease) async throws {').replace('func retire(', 'override func retire(', 1)
    extras = declaration(provider, '    private enum RetirementDiagnosticStage:') + '\n' + declaration(provider, '    private func reportUnconfirmedRetirement(')
    fixture = fixture.replace('// ACTUAL_STOP_PROVIDER', '@MainActor final class ActualStopProvider: StopFixture {\n' + retirement + '\n' + extras + '\n}')
    (output / 'Retirement.swift').write_text(fixture)
    for name, spec in [('privacy', ROOT / 'macos/GalaxyBridgeMacTests/MediaFailureDiagnosticsSpec.swift'),
                       ('retirement', output / 'Retirement.swift')]:
        binary = output / name
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                        str(output / 'Diagnostic.swift'), str(output / 'FailureTypes.swift'), str(spec), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
