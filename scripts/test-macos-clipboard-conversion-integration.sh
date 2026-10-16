#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-clipboard-integration.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
python3 - "$GB_ROOT" "$GB_TMP" <<'PYEXTRACT'
from pathlib import Path
import os, sys
root, output = map(Path, sys.argv[1:])
source = Path(os.environ.get('GB_CLIPBOARD_APP_MODEL_SOURCE', root / 'macos/GalaxyBridgeMac/AppModel.swift')).read_text()
methods = []
start = source.index('        CompanionLifecycleEvents.pairingStoredPublisher()')
end = source.index('            .store(in: &cancellables)', start) + len('            .store(in: &cancellables)')
observer = source[start:end].replace('pairingStoredPublisher()', 'pairingStoredPublisher(in: notificationCenter)')
methods.append('func installPairingObserver(in notificationCenter: NotificationCenter) {\n' + observer + '\n}')
for name in ['featureEnabled', 'publishClipboardIfChanged', 'acceptConvertedClipboard', 'acceptRemoteClipboard', 'clipboardRecipients', 'broadcastClipboard', 'revalidateClipboardTrust', 'clipboardRouteIDs', 'acceptEnhancedClipboard', 'enhancedClipboardIdentity']:
    marker = '    private func ' + name + '('
    if marker not in source and '    func ' + name + '(' in source: marker = '    func ' + name + '('
    if marker not in source:
        if name in ['acceptConvertedClipboard', 'clipboardRecipients', 'revalidateClipboardTrust', 'clipboardRouteIDs', 'acceptEnhancedClipboard', 'enhancedClipboardIdentity']: continue
        raise RuntimeError('Missing actual clipboard poll method')
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{': depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                methods.append(source[start:index + 1].replace('private func', 'func', 1).replace('NSPasteboard.general', 'clipboardPasteboard'))
                break
    else: raise RuntimeError('Cannot locate clipboard method body')
start = source.index('    private func installEnhancedClipboardSession(')
opening = source.index('{', source.index('readyHandler:', start)); depth = 0
for index in range(opening, len(source)):
    if source[index] == '{': depth += 1
    elif source[index] == '}':
        depth -= 1
        if depth == 0:
            ready = source[opening:index + 1]; break
methods.append('func captureFreeReady(deviceID: String, readySerial: String) { let ready: (String) -> Void = ' + ready + '; ready(readySerial) }')
start = source.index('            session.$state.sink', source.index('    func ensureEnhancedSession('))
start = source.index('                case .streaming:', start) + len('                case .streaming:')
end = source.index('                case .failed:', start)
methods.append('func primaryStreamingReady(targetID: String, serial: String) { let route = TestCaptureRoute(); ' + source[start:end] + '\n self.mergeDevices() }')
marker = '    private struct ClipboardRecipient {'
if marker in source:
    start = source.index(marker); end = source.index('\n    }', start) + 6
    methods.insert(0, '@MainActor ' + source[start:end].lstrip().replace('private struct', 'struct', 1))
fingerprint = (root / 'macos/GalaxyBridgeMac/Transport/OutgoingFileTransferStore.swift').read_text()
start = fingerprint.index('    static func peerFingerprint('); end = fingerprint.index('\n    }', start) + 6
fingerprintFacade = 'enum OutgoingFileTransferStore {\n' + fingerprint[start:end] + '\n}'
fixture = (root / 'macos/GalaxyBridgeMacTests/ClipboardConversionIntegrationSpec.swift').read_text()
(output / 'ClipboardConversionIntegrationSpec.swift').write_text(fixture.replace('// ACTUAL_APP_MODEL_CLIPBOARD_METHODS', '\n'.join(methods)).replace('// ACTUAL_PEER_FINGERPRINT', fingerprintFacade))
PYEXTRACT
xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeCore \
  "$GB_ROOT/Sources/GalaxyBridgeCore/EncryptedPayload.swift" -o "$GB_TMP/libGalaxyBridgeCore.dylib"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -I "$GB_TMP" -L "$GB_TMP" -lGalaxyBridgeCore -I "$GB_ROOT/Sources/CSQLite" -lsqlite3 \
  -framework Security -framework LocalAuthentication \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage/EncryptedContentCache.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage/NotificationCacheRemovalAttempt.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage/ContentCacheMaintenanceCoordinator.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionLifecycleEvents.swift" \
  -module-cache-path "$GB_TMP/modules" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ClientSetupModel.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ClipboardPayloadPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ClipboardConversionWorker.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ClipboardHubState.swift" \
  "$GB_TMP/ClipboardConversionIntegrationSpec.swift" \
  -o "$GB_TMP/ClipboardConversionIntegrationSpec"
DYLD_LIBRARY_PATH="$GB_TMP" "$GB_TMP/ClipboardConversionIntegrationSpec"
