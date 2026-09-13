#!/bin/sh
set -eu
GB_QA_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$GB_QA_ROOT/android"
./gradlew --console=plain \
  :app:testInternalDebugUnitTest --tests '*DownloadsProviderQaSurfaceTest' --tests '*AudioVideoQaSignalTest' \
  :app:testDirectDebugUnitTest --tests '*DownloadsProviderQaSurfaceTest' \
  :app:testPlayDebugUnitTest --tests '*DownloadsProviderQaSurfaceTest' \
  :app:compileInternalReleaseKotlin :app:compileDirectReleaseKotlin :app:compilePlayReleaseKotlin \
  :app:processInternalReleaseManifest :app:processDirectReleaseManifest :app:processPlayReleaseManifest
python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
root = Path('app/build/intermediates')
android = '{http://schemas.android.com/apk/res/android}'
for flavor in ('internal', 'direct', 'play'):
    variant = flavor + 'Release'
    title = variant[0].upper() + variant[1:]
    manifest = root / 'merged_manifests' / variant / ('process' + title + 'Manifest') / 'AndroidManifest.xml'
    app = ET.parse(manifest).getroot().find('application')
    assert app is not None and app.get(android + 'debuggable', 'false') == 'false', variant
    assert not any(any(name in e.get(android + 'name', '') for name in ('DownloadsProviderQaReceiver', 'TextInputQaActivity', 'AudioVideoQaActivity')) for e in app), variant
    classes = root / 'built_in_kotlinc' / variant / ('compile' + title + 'Kotlin') / 'classes'
    assert (classes / 'com/xopmc/galaxybridge/MainActivity.class').is_file(), variant + ' was not compiled'
    for pattern in ('DownloadsProviderQaReceiver*.class', 'ProviderRun*.class', 'QaDatabaseContext*.class', 'TextInputQaActivity*.class', 'AudioVideoQa*.class'):
        assert not list(classes.rglob(pattern)), variant + ' leaked QA bytecode: ' + pattern
    print('PASS', variant, 'non-debuggable manifest and bytecode exclude downloads, text and A/V QA fixtures')
PY
