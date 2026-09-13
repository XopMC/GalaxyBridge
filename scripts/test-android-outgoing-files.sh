#!/bin/sh
set -eu
GB_FILES_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$GB_FILES_ROOT/android"
./gradlew --console=plain \
  :app:testInternalDebugUnitTest --tests '*OutgoingFileSenderTest' --tests '*FileSendPolicyTest' --tests '*CompanionControlPayloadPolicyTest' \
  :app:testDirectDebugUnitTest --tests '*OutgoingFileSenderTest' --tests '*FileSendPolicyTest' \
  :app:testPlayDebugUnitTest --tests '*FileSendPolicyTest' \
  :app:compileInternalReleaseKotlin :app:compileDirectReleaseKotlin :app:compilePlayReleaseKotlin \
  :app:processInternalReleaseManifest :app:processDirectReleaseManifest :app:processPlayReleaseManifest
python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
android = '{http://schemas.android.com/apk/res/android}'
for flavor in ('internal', 'direct', 'play'):
    variant = flavor + 'Release'
    title = variant[0].upper() + variant[1:]
    path = Path('app/build/intermediates/merged_manifests') / variant / ('process' + title + 'Manifest') / 'AndroidManifest.xml'
    app = ET.parse(path).getroot().find('application')
    activities = [e for e in app.findall('activity') if e.get(android + 'name', '').endswith('.FileShareActivity')]
    assert len(activities) == (0 if flavor == 'play' else 1), flavor
    if activities:
        activity = activities[0]
        assert activity.get(android + 'exported') == 'true'
        actions = [e.get(android + 'name') for e in activity.findall('intent-filter/action')]
        assert actions == ['android.intent.action.SEND'], (flavor, actions)
    print('PASS', flavor, 'single-file share target exposure')
PY
