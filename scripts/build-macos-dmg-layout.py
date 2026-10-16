#!/usr/bin/env python3
"""Build Finder presentation without driving Finder or changing its preferences."""
import argparse
from pathlib import Path
import sys
import tempfile

try:
    import dmgbuild
except ImportError:
    raise SystemExit(
        'DMG layout tools are missing. Run scripts/bootstrap-build-tools.py and add '
        'the build tree tools/bin to PATH, or install scripts/dmg-layout-requirements.txt '
        'with pip --require-hashes in your build environment.'
    )

ROOT = Path(__file__).resolve().parents[1]
WINDOW_SIZE = (780, 660)
ICON_POSITIONS = {
    'Galaxy Bridge.app': (200, 270), 'Applications': (580, 270),
    # Also keep support files away from the artwork for "Show hidden files" users.
    '.background.tiff': (1200, 1200), '.VolumeIcon.icns': (1400, 1200),
    '.metadata_never_index': (1600, 1200),
}


def build(app: Path, output: Path) -> None:
    if sys.platform != 'darwin':
        raise SystemExit('DMG packaging requires macOS.')
    artwork = ROOT / 'assets/dmg/background.tiff'
    icon = app / 'Contents/Resources/GalaxyBridge.icns'
    if not artwork.is_file() or not icon.is_file():
        raise SystemExit('DMG background or source application icon is missing.')
    # The shell entry point owns output validation, staging and atomic no-clobber
    # publication. dmgbuild works only on that entry point's private output.
    settings = {
        'symlinks': {'Applications': '/Applications'},
        'background': str(artwork),
        'icon': str(icon),
        'format': 'UDZO',
        'filesystem': 'HFS+',
        'window_rect': ((180, 160), WINDOW_SIZE),
        'default_view': 'icon-view',
        'show_toolbar': False,
        'show_sidebar': False,
        'show_status_bar': False,
        'show_pathbar': False,
        'show_tab_view': False,
        'icon_size': 96,
        'text_size': 15,
        'grid_spacing': 80,
        'arrange_by': None,
        'icon_locations': ICON_POSITIONS,
        # SetFile on a signed .app adds FinderInfo that invalidates strict code
        # verification. Preserve the bundle, including its extension metadata.
        'hide': ['.background.tiff', '.VolumeIcon.icns', '.metadata_never_index'],
        'include_icon_view_settings': True,
        'include_list_view_settings': False,
    }
    with tempfile.TemporaryDirectory(prefix='.finder-metadata-', dir=output.parent) as temporary:
        marker = Path(temporary) / '.metadata_never_index'
        marker.touch()
        # Suppress indexing before the application is copied onto the volume.
        settings['files'] = [(str(marker), marker.name), (str(app), 'Galaxy Bridge.app')]
        dmgbuild.build_dmg(str(output), 'Galaxy Bridge', settings=settings, lookForHiDPI=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    build(args.app.resolve(), args.output.resolve())
