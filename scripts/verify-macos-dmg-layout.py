#!/usr/bin/env python3
"""Check a mounted installer, including portable Finder metadata and asset privacy."""
from pathlib import Path
import re
import sys
from ds_store import DSStore
from mac_alias import Alias

root = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    raise SystemExit('usage: verify-macos-dmg-layout.py MOUNTED_VOLUME')
volume = Path(sys.argv[1])
assert (volume / 'Applications').is_symlink()
assert str((volume / 'Applications').readlink()) == '/Applications'
assert (volume / 'Galaxy Bridge.app/Contents/Info.plist').is_file()
assert (volume / '.metadata_never_index').is_file()
art = volume / '.background.tiff'
assert art.read_bytes() == (root / 'assets/dmg/background.tiff').read_bytes()
assert (volume / '.VolumeIcon.icns').read_bytes() == (
    volume / 'Galaxy Bridge.app/Contents/Resources/GalaxyBridge.icns').read_bytes()
metadata = (volume / '.DS_Store').read_bytes()
for private_path in ['/Users/', '/private/var/', '/var/folders/']:
    for encoding in ['utf-8', 'utf-16-be', 'utf-16-le']:
        assert private_path.encode(encoding) not in metadata, 'Private build path in Finder metadata'
with DSStore.open(str(volume / '.DS_Store'), 'r') as store:
    options = store['.']['icvp']
    window = store['.']['bwsp']
    assert store['.']['icvl'][1] == b'icnv'
    assert options['backgroundType'] == 2 and options['arrangeBy'] == 'none'
    assert options['labelOnBottom'] and options['iconSize'] >= 80
    assert not any(window.get(key) for key in ['ShowToolbar', 'ShowSidebar', 'ShowStatusBar', 'ShowPathbar', 'ShowTabView'])
    width, height = map(int, re.findall(r'\d+', window['WindowBounds'])[-2:])
    assert width >= 760 and height >= 650, 'Instructions need room for visible Finder chrome'
    app = store['Galaxy Bridge.app']['Iloc']
    folder = store['Applications']['Iloc']
    assert app[1] == folder[1] and app[0] < 348 < 432 < folder[0] < width
    assert 200 <= app[1] <= 300
    for name in ['.background.tiff', '.VolumeIcon.icns', '.metadata_never_index']:
        x, y = store[name]['Iloc']
        assert x > width and y > height, 'Hidden assets must not overlap the installation artwork'
    alias = Alias.from_bytes(options['backgroundImageAlias'])
    assert alias.volume.name == 'Galaxy Bridge'
    assert alias.target.filename == '.background.tiff'
    assert alias.target.posix_path == '/.background.tiff'
    assert alias.volume.posix_path.startswith('/Volumes/Galaxy Bridge')
print('PASS Finder installer: two aligned drag targets, arrow gap, roomy window, Retina artwork, portable background alias and no private build paths')
