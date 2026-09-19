import Foundation
import GalaxyBridgeCore

struct DeviceRow: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let transport: TransportKind
    let isReady: Bool
    let adbSerial: String?
    let companionID: String?

    init(
        id: String,
        name: String,
        subtitle: String,
        transport: TransportKind,
        isReady: Bool,
        adbSerial: String? = nil,
        companionID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.transport = transport
        self.isReady = isReady
        self.adbSerial = adbSerial
        self.companionID = companionID
    }
}

/// A Helper's Bonjour advertisement proves only that something is reachable on
/// the LAN. The device list is user-owned state, so discovery becomes visible
/// only after the signed pairing commit created a trusted peer.
enum CompanionDiscoveryPresentationPolicy {
    static func shouldPublish(hasCommittedPeer: Bool) -> Bool {
        hasCommittedPeer
    }
}

/// Keeps an ADB route whose identity proof is still in flight out of the
/// sidebar when the same phone already has a canonical Companion row. The
/// route is not merged or made usable until its signed proof succeeds; this
/// policy only prevents a transient duplicate from leaking into presentation.
enum ADBPendingIdentityPresentationPolicy {
    static func shouldPublishStandalone(
        hasCanonicalCompanionRow: Bool,
        hasPersistentlyVerifiedBinding: Bool,
        matchingCompanionCount: Int
    ) -> Bool {
        // ADB discovery is transport discovery, not an explicit user action.
        // Never turn remembered USB/Wi-Fi authorizations into new sidebar
        // devices. A route becomes visible through its paired Companion identity
        // or through the separately verified persisted binding handled before
        // this policy is consulted.
        _ = (hasCanonicalCompanionRow, hasPersistentlyVerifiedBinding, matchingCompanionCount)
        return false
    }
}

/// Reuses a previously signed Wireless ADB alias after an application restart
/// only when the currently connected endpoint still exposes the exact hardware
/// serial captured by that signed binding. Model names and network addresses
/// are intentionally insufficient: either mismatch falls back to a fresh
/// Companion nonce proof.
enum PersistedWirelessADBBindingPolicy {
    static func canRestoreTrustedRoute(
        identityBindingIsVerified: Bool,
        storedHardwareSerial: String?,
        currentHardwareSerial: String?
    ) -> Bool {
        guard identityBindingIsVerified,
              let stored = normalized(storedHardwareSerial),
              let current = normalized(currentHardwareSerial)
        else { return false }
        return stored == current
    }

    private static func normalized(_ serial: String?) -> String? {
        guard let value = serial?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}

/// Internal hardware QA may select one exact route while excluding another
/// alias of the same phone. The exact selector wins for that one endpoint;
/// exclusions remain alias-wide for every other route so unrelated devices
/// cannot leak into the run.
enum ADBHardwareQAIsolationPolicy {
    static func routeIsExcluded(
        serial: String,
        requiredSerial: String?,
        boundHardwareSerial: String?,
        boundDeviceID: String?,
        excludedSerials: Set<String>,
        excludedDeviceIDs: Set<String>
    ) -> Bool {
        if serial == requiredSerial { return false }
        if excludedSerials.contains(serial) { return true }
        if let boundHardwareSerial, excludedSerials.contains(boundHardwareSerial) { return true }
        if let boundDeviceID, excludedDeviceIDs.contains(boundDeviceID.lowercased()) { return true }
        return false
    }
}

/// Combines routes only after AppModel has assigned the same logical identity
/// through its existing trust checks. This is not an alias/identity resolver.
enum DeviceRowMerger {
    static func merge(_ left: DeviceRow, _ right: DeviceRow) -> DeviceRow {
        let selected: DeviceRow
        if left.isReady != right.isReady {
            selected = left.isReady ? left : right
        } else if left.transport != right.transport {
            // Also deterministic when all routes are offline: show the best
            // known route for reconnect, without claiming that it is ready.
            selected = TransportSelector.preferred(from: [left.transport, right.transport]) == left.transport
                ? left : right
        } else {
            // Equal-priority verified aliases should not switch endpoints just
            // because discovery order changes. A known serial sorts before nil.
            switch (left.adbSerial, right.adbSerial) {
            case let (.some(a), .some(b)):
                selected = a <= b ? left : right
            case (.some, .none):
                selected = left
            case (.none, .some):
                selected = right
            case (.none, .none):
                selected = left
            }
        }
        let transports = TransportSelector.presented(
            from: [
                TransportSnapshot(kind: left.transport, isConnected: left.isReady, capabilities: []),
                TransportSnapshot(kind: right.transport, isConnected: right.isReady, capabilities: []),
            ]
        )
        let subtitle = TransportSelector.connectionLabelKeys(for: transports)
            .map(UserFacingText.localized).joined(separator: " + ")
        return DeviceRow(
            id: left.id,
            name: left.companionID == nil ? right.name : left.name,
            subtitle: subtitle,
            transport: selected.transport,
            isReady: selected.isReady,
            adbSerial: selected.transport == .companionLAN ? nil : selected.adbSerial,
            companionID: left.companionID ?? right.companionID
        )
    }
}
