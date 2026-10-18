#!/usr/bin/env python3
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(os.environ.get('GB_CATALOG_TEST_ROOT', Path(__file__).resolve().parents[1]))
spec = Path(os.environ.get('GB_CATALOG_DECODE_SPEC_SOURCE', root / 'macos/GalaxyBridgeMacTests/ApplicationCatalogBrokerDecodeSpec.swift'))
def declaration(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return source[start:end + 1]
    raise RuntimeError(marker)
provider = (root / 'macos/GalaxyBridgeMac/Transport/ShellCapabilityBridgeProvider.swift').read_text()
model = (root / 'macos/GalaxyBridgeMac/ApplicationCatalog.swift').read_text()
fixture = spec.read_text().replace('    // ACTUAL_FETCH', declaration(provider, '    func fetchApplicationCatalog()'))
fixture = fixture.replace('// ACTUAL_ITEM', declaration(model, 'struct ApplicationCatalogItem:'))
manifest = (root / 'macos/GalaxyBridgeMac/ApplicationCatalogExportManifest.swift').read_text()
# Keep the real parser; the wrapper only controls its scheduling boundary.
manifest = manifest.replace('ApplicationCatalogExportManifest', 'ActualApplicationCatalogExportManifest')
with tempfile.TemporaryDirectory(prefix='gb-catalog-decode-') as temporary:
    folder = Path(temporary)
    actual = folder / 'ActualCatalogBroker.swift'
    parser = folder / 'ActualManifest.swift'
    actual.write_text(fixture)
    parser.write_text(manifest)
    binary = folder / 'spec'
    subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                    str(actual), str(parser), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
