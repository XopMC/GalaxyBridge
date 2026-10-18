#!/usr/bin/env python3
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(os.environ.get('GB_CATALOG_TEST_ROOT', Path(__file__).resolve().parents[1]))
spec = Path(os.environ.get('GB_CATALOG_ICON_SPEC_SOURCE', root / 'macos/GalaxyBridgeMacTests/ApplicationCatalogIconRefreshSpec.swift'))
source = (root / 'macos/GalaxyBridgeMac/ApplicationCatalogEnhancedClient.swift').read_text()
start = source.index('    private func iconPNG(')
opening = source.index('{', start)
depth = 0
for end in range(opening, len(source)):
    if source[end] == '{':
        depth += 1
    elif source[end] == '}':
        depth -= 1
        if depth == 0:
            method = source[start:end + 1].replace('private func', 'func', 1)
            break
else:
    raise RuntimeError('Icon method is incomplete')
with tempfile.TemporaryDirectory(prefix='gb-icon-refresh-') as temporary:
    folder = Path(temporary)
    actual = folder / 'ActualIconRefresh.swift'
    actual.write_text(spec.read_text().replace('    // ACTUAL_ICON', method))
    binary = folder / 'spec'
    subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                    str(root / 'macos/GalaxyBridgeMac/ApplicationIconCache.swift'), str(actual),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
