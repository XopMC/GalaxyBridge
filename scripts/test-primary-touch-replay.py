#!/usr/bin/env python3
"""Finite QA generator and wire qualification checks; no device or app operations."""
from pathlib import Path
import subprocess
import tempfile
import resource

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

root = Path(__file__).resolve().parents[1]
media = root / 'macos/GalaxyBridgeMac/Media'
specs = root / 'macos/GalaxyBridgeMacTests'
arguments = ['--primary-media-diagnostics', '--primary-input-marker-nonce=270544960', '--qa-touch-replay-peer=device:fixture']
with tempfile.TemporaryDirectory(prefix='gb-touch-replay-spec-') as temporary:
    for name, source, qa in [('marker', 'PrimaryTouchReplayMarkerSpec.swift', True),
                             ('scheduler', 'PrimaryTouchReplaySpec.swift', True),
                             ('ordinary', 'PrimaryTouchReplayMarkerSpec.swift', False)]:
        binary = Path(temporary) / name
        command = ['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                   str(media / 'PrimaryMediaDiagnostics.swift'), str(specs / source), '-framework', 'CoreVideo', '-o', str(binary)]
        if qa:
            command += ['-DGB_INPUT_REPLAY_QA', str(media / 'PrimaryTouchReplay.swift')]
        subprocess.run(command, cwd=root, check=True)
        subprocess.run([str(binary), *arguments, *([] if qa else ['--expect-normal'])], check=True)
