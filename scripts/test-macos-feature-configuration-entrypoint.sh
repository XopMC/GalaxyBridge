#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-feature-entrypoint.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os, sys
root, out = map(Path, sys.argv[1:])
source = Path(os.environ.get('GB_FEATURE_APP_MODEL_SOURCE', root / 'macos/GalaxyBridgeMac/AppModel.swift')).read_text()
methods=[]
for name in ['featureEnabled','setFeatureSelection','reconcileFeatureConfiguration','resetFeatureConfigurationForSession','startConfiguredCompanionMedia','handleFeatureConfigurationResult','handleFeatureMediaState','requestRemoteClipboard','sendEnhancedClipboardCommandViaCompanion']:
    start=source.find('    func '+name+'(')
    if start < 0: start=source.find('    private func '+name+'(')
    if start < 0: continue
    opening=source.index('{',start); depth=0
    for end in range(opening,len(source)):
        if source[end]=='{': depth+=1
        elif source[end]=='}':
            depth-=1
            if depth==0:
                methods.append(source[start:end+1].replace('private func','func',1));break
if '    private func handleFeatureConfigurationResult(' not in source:
    start=source.index('        case let .featureConfigurationResult(result):')+len('        case let .featureConfigurationResult(result):')
    end=source.index('        case let .capabilityUpdate',start)
    methods.append('func handleFeatureConfigurationResult(companionID: String, deviceID: String, envelope: GBEnvelope, result: GBFeatureConfigurationResult) {\n'+source[start:end]+'\n}')
# Execute the actual new-owner constructor and first playback binding, with inert native boundaries.
start=source.index('            let session = ScrcpySession(',source.index('    func ensureEnhancedSession('))
end=source.index('\n            scrcpySessions[',start)
methods.append('func createActualEnhancedSession(device: DeviceRow) throws -> ScrcpySession { let serial = "synthetic"; let route = Route(); let preservePhoneDisplay = false; '+source[start:end]+'; return session }')
start=source.index('        let surface = videoSurface(for: deviceID)',source.index('    private func bindEnhancedNativeFrames('))
end=source.index('        session.recordingAudioEventHandler',start)
methods.append('func bindActualEnhancedPlayback(_ session: ScrcpySession, deviceID: String) { '+source[start:end]+' _ = surface }')
fixture=(root/'macos/GalaxyBridgeMacTests/FeatureConfigurationEntryPointSpec.swift').read_text()
if os.environ.get('GB_FEATURE_RED_FIRST_ONLY') == '1':
    end=fixture.index('        let request = model.companionClients')
    fixture=fixture[:end]+'    }\n}\n'
(out/'ActualFeatureConfiguration.swift').write_text(fixture.replace('// ACTUAL_FEATURE_ENTRY_POINTS','\n'.join(methods)))
PY
swiftc -swift-version 6 -parse-as-library "$root/macos/GalaxyBridgeMac/ClientSetupModel.swift" "$root/macos/GalaxyBridgeMac/ClipboardHubState.swift" "$tmp/ActualFeatureConfiguration.swift" -o "$tmp/spec"
"$tmp/spec"
