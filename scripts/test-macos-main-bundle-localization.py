#!/usr/bin/env python3
"""Keep Direct-app localization out of SwiftPM's fragile module bundle lookup."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
package = (ROOT / "Package.swift").read_text()
text = (ROOT / "macos/GalaxyBridgeMac/UserFacingText.swift").read_text()
stager = (ROOT / "scripts/public-build.py").read_text()

assert 'resources: [.process("Resources")]' not in package
assert 'exclude: ["Info.plist", "Assets.xcassets", "Resources"]' in package
assert 'UserFacingTextResolver(bundle: .main)' in text
assert "for locale in (ROOT / 'macos/GalaxyBridgeMac/Resources').glob('*.lproj')" in stager
assert 'GalaxyBridge_GalaxyBridgeMac.bundle' not in stager

if len(sys.argv) == 2:
    app = Path(sys.argv[1]).resolve()
    resources = app / 'Contents/Resources'
    assert app.is_dir(), f'Application is missing: {app}'
    assert not (resources / 'GalaxyBridge_GalaxyBridgeMac.bundle').exists()
    for source_locale in (ROOT / 'macos/GalaxyBridgeMac/Resources').glob('*.lproj'):
        staged_locale = resources / source_locale.name / 'Localizable.strings'
        assert staged_locale.is_file(), f'Localization is missing: {staged_locale}'
        assert staged_locale.read_bytes() == (source_locale / 'Localizable.strings').read_bytes()

print("macOS Direct localization uses the main application bundle: PASS")
