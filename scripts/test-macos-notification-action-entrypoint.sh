#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gb-notification-entrypoint.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
# Compile the actual production submission methods with inert transport/model boundaries.
# In particular, no test-side copy may reorder the draft-admission/connection guards.
python3 - "$GB_ROOT" "$GB_TMP" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root / 'macos/GalaxyBridgeMac/AppModel.swift').read_text()
start = source.index('    func canSendNotificationAction(deviceID: String)')
end = source.index('\n#if !GALAXYBRIDGE_APP_STORE\n', start)
listing_start = source.index('    func notifications(for deviceID: String)')
listing_end = source.index('    func mutedPackages(for deviceID: String)', listing_start)
feature_start = source.index('    func featureEnabled(')
feature_end = source.index('\n    }', feature_start) + len('\n    }')
models_start = source.index('struct BridgeNotificationActionRow:')
models_end = source.index('struct BridgeSMSRow:', models_start)
boundaries = '''import Foundation
// ACTUAL_NOTIFICATION_MODELS
struct GBNotificationAction { var notificationID = ""; var actionID = ""; var replyText = ""; var dismiss = false; var requestID = "" }
final class CompanionTLSClient { var supportsNotificationActionResults = true; var sent: [GBNotificationAction] = []; func sendNotificationAction(_ action: GBNotificationAction) throws { sent.append(action) } }
final class Supervisor { var generation: UInt64? = 4; func currentGeneration(companionID: String) -> UInt64? { generation } }
@MainActor final class AppModel {
let clientSetup: ClientSetupModel
init(featureStorageURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("gb-notification-features-" + UUID().uuidString).appendingPathComponent("choices.json")) {
    clientSetup = ClientSetupModel(storageURL: featureStorageURL)
}
var notificationActions = NotificationActionState()
private var notificationActionTimeouts: [String: Task<Void, Never>] = [:]
private var notificationActionCleanup: Task<Void, Never>?
private var notificationActionSavedRows: [NotificationActionIdentity: BridgeNotificationRow] = [:]
var notificationsByDevice: [String: [BridgeNotificationRow]] = [:]
var lastError: String?
var companionRecoverySupervisor = Supervisor()
var control: CompanionTLSClient?
func companionControl(for deviceID: String) -> CompanionTLSClient? { control }
func companionID(for deviceID: String) -> String? { control == nil ? nil : "route" }
func mutedPackages(for deviceID: String) -> Set<String> { [] }
}
'''
# Keep the extracted methods inside the harness class.
(temp / 'AppModelNotificationEntryPoint.swift').write_text(boundaries.replace('// ACTUAL_NOTIFICATION_MODELS', source[models_start:models_end])[:-2] + source[feature_start:feature_end] + '\n' + source[listing_start:listing_end] + source[start:end] + '\n}\n')
PY
xcrun swiftc "$GB_ROOT/macos/GalaxyBridgeMac/ClientSetupModel.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/NotificationActionState.swift" \
  "$GB_TMP/AppModelNotificationEntryPoint.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/NotificationActionEntryPointSpec.swift" \
  -o "$GB_TMP/NotificationActionEntryPointSpec"
"$GB_TMP/NotificationActionEntryPointSpec"
