#!/usr/bin/env python3
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(os.environ.get('GB_CATALOG_TEST_ROOT', Path(__file__).resolve().parents[1]))
source = Path(os.environ.get('GB_CATALOG_MODEL_SOURCE', root / 'macos/GalaxyBridgeMac/AppModel.swift')).read_text()
start = source.index('    func loadApplicationCatalog(')
opening = source.index('{', start)
depth = 0
for end in range(opening, len(source)):
    if source[end] == '{':
        depth += 1
    elif source[end] == '}':
        depth -= 1
        if depth == 0:
            method = source[start:end + 1]
            break
else:
    raise RuntimeError('Catalog method is incomplete')
spec = Path(os.environ.get('GB_CATALOG_LOADER_SPEC_SOURCE', root / 'macos/GalaxyBridgeMacTests/ApplicationCatalogLoaderSpec.swift'))
with tempfile.TemporaryDirectory(prefix='gb-catalog-loader-') as temporary:
    folder = Path(temporary)
    actual = folder / 'ActualCatalogLoader.swift'
    actual.write_text(spec.read_text().replace('    // ACTUAL_LOAD', method))
    binary = folder / 'spec'
    subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                    str(actual), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
