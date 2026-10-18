#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-privacy-entry.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import os,sys
root,out=map(Path,sys.argv[1:])
source=Path(os.environ.get('GB_PHONE_PRIVACY_APP_MODEL_SOURCE',root/'macos/GalaxyBridgeMac/AppModel.swift')).read_text()
methods=[]
for name in ['phoneDisplayPrivacyEnabled','retryPhoneDisplayPrivacy','setPhoneDisplayPrivacy','setDisplayPower','activePhoneDisplayInteraction','configurePhoneDisplayInteraction','publishCompositePhoneDisplayStatus','phoneDisplaySessionReady','releasePhoneDisplaySession','canonicalPhonePrivacyID','requestPhoneDisplayPrivacyUpdate','reconcilePhoneDisplayPrivacyRoutes']:
 start=source.find('    func '+name+'(')
 if start<0 and name=='retryPhoneDisplayPrivacy':continue
 if start<0:start=source.index('    private func '+name+'(')
 opening=source.index('{',start);depth=0
 for end in range(opening,len(source)):
  if source[end]=='{':depth+=1
  elif source[end]=='}':
   depth-=1
   if depth==0:methods.append(source[start:end+1].replace('private func','func',1));break
start=source.index('session.$phoneDisplayPrivacyReady.sink ')+len('session.$phoneDisplayPrivacyReady.sink ')
opening=source.index('{',start);depth=0
for end in range(opening,len(source)):
 if source[end]=='{':depth+=1
 elif source[end]=='}':
  depth-=1
  if depth==0:break
methods.append('func capturePrimaryReadiness(session: ScrcpySession, preservePhoneDisplay: Bool = false) -> (Bool) -> Void { return '+source[opening:end+1]+' }')
methods.append('func publishPrimaryReadiness(_ ready: Bool, session: ScrcpySession, preservePhoneDisplay: Bool = false) { let callback = capturePrimaryReadiness(session: session, preservePhoneDisplay: preservePhoneDisplay); callback(ready) }')
application=(root/'macos/GalaxyBridgeMac/ApplicationWindowCoordinator.swift').read_text()
start=application.index('session.nativeSession.$phoneDisplayPrivacyReady.sink ')+len('session.nativeSession.$phoneDisplayPrivacyReady.sink ')
opening=application.index('{',start);depth=0
for end in range(opening,len(application)):
 if application[end]=='{':depth+=1
 elif application[end]=='}':
  depth-=1
  if depth==0:break
methods.append('func publishApplicationReadiness(_ ready: Bool, session: ScrcpySession, deviceID: String, lease: UUID) { let model: AppModel? = self; let identity = DeviceRow(id: deviceID); let serial = session.serial; let privacyLease = lease; let callback: (Bool) -> Void = '+application[opening:end+1]+'; callback(ready) }')
view=(root/'macos/GalaxyBridgeMac/ContentView.swift').read_text()
start=view.index('if case .failed = model.phoneDisplayPrivacyStatuses[device.id]')
opening=view.index('{',view.index('Button("RETRY")',start));depth=0
for end in range(opening,len(view)):
 if view[end]=='{':depth+=1
 elif view[end]=='}':
  depth-=1
  if depth==0:break
methods.append('func retryFromVisibleControl(deviceID: String) { let model = self; let device = DeviceRow(id: deviceID); '+view[opening+1:end]+' }')
fixture=(root/'macos/GalaxyBridgeMacTests/PhonePrivacyEntryPointSpec.swift').read_text()
(out/'ActualPrivacyEntryPoint.swift').write_text(fixture.replace('// ACTUAL_PHONE_PRIVACY_METHODS','\n'.join(methods)))
PY
swiftc -swift-version 6 -emit-module -emit-library -module-name GalaxyBridgeCore "$root/Sources/GalaxyBridgeCore/PhoneDisplayPrivacy.swift" -o "$tmp/libGalaxyBridgeCore.dylib" -emit-module-path "$tmp/GalaxyBridgeCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$tmp" -L "$tmp" -lGalaxyBridgeCore -Xlinker -rpath -Xlinker "$tmp" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayStateControllerProtocol.swift" \
  "$root/macos/GalaxyBridgeMac/PhoneDisplayInteractionCoordinator.swift" \
  "$root/macos/GalaxyBridgeMac/PhoneDisplayPrivacyCoordinator.swift" "$tmp/ActualPrivacyEntryPoint.swift" -o "$tmp/spec"
"$tmp/spec"
