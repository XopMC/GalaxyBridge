import Foundation
import CryptoKit

struct ClipboardDeliveryEpoch: Equatable, Sendable {
    let trustGeneration: UUID
    let routeIDs: Set<String>
}

enum ClipboardDeliveryKind: UInt8, Sendable { case text, png }

/// Process-local ordering and loop suppression for the shared Mac/Galaxy
/// clipboard. `AppModel` is main-actor isolated, so assigning the revision at
/// ingress gives every real copy event one deterministic total order.
enum ClipboardHubRemoteDecision: Equatable, Sendable {
    case accept(revision: UInt64)
    case duplicate
}

struct ClipboardHubState: Sendable {
    private let seenCapacity: Int
    private var revision: UInt64 = 0
    private var seenChangeIDs = Set<String>()
    private var seenChangeIDOrder: [String] = []
    private struct PhoneClipboard: Sendable {
        let epoch: ClipboardDeliveryEpoch
        let kind: ClipboardDeliveryKind
        let digest: Data
        let confirmed: Bool
    }
    private var phoneClipboards: [String: PhoneClipboard] = [:]
    private var phoneOrder: [String] = []

    init(seenCapacity: Int = 512) {
        precondition(seenCapacity > 0)
        self.seenCapacity = seenCapacity
    }

    mutating func acceptRemote(
        sourceDeviceID: String,
        changeID: String,
        now: Date = Date()
    ) -> ClipboardHubRemoteDecision {
        _ = sourceDeviceID
        _ = now
        guard remember(changeID: changeID) else { return .duplicate }
        return .accept(revision: nextRevision())
    }

    mutating func acceptMacChange() -> UInt64 {
        nextRevision()
    }

    mutating func outboundChangeID(revision: UInt64) -> String {
        let value = "hub:\(revision):\(UUID().uuidString.lowercased())"
        _ = remember(changeID: value)
        return value
    }

    /// Occurrence ordering and physical writes are separate: OEM clipboard
    /// managers can recreate the same payload with a new ID and timestamp.
    /// Keep accepting those occurrences without rewriting every other phone.
    func needsDelivery(deviceID: String, epoch: ClipboardDeliveryEpoch,
                       kind: ClipboardDeliveryKind, content: Data) -> Bool {
        guard let current = phoneClipboards[deviceID], current.epoch == epoch, current.confirmed else { return true }
        return current.kind != kind || current.digest != Data(SHA256.hash(data: content))
    }

    mutating func observeClipboard(deviceID: String, epoch: ClipboardDeliveryEpoch,
                                  kind: ClipboardDeliveryKind, content: Data, confirmed: Bool = false) {
        let digest = Data(SHA256.hash(data: content))
        let prior = phoneClipboards[deviceID]
        let retainsConfirmation = prior?.epoch == epoch && prior?.kind == kind && prior?.digest == digest && prior?.confirmed == true
        phoneClipboards[deviceID] = PhoneClipboard(epoch: epoch, kind: kind, digest: digest, confirmed: confirmed || retainsConfirmation)
        phoneOrder.removeAll { $0 == deviceID }
        phoneOrder.append(deviceID)
        while phoneOrder.count > 64 { phoneClipboards.removeValue(forKey: phoneOrder.removeFirst()) }
    }

    mutating func forgetClipboard(deviceID: String) {
        phoneClipboards.removeValue(forKey: deviceID)
        phoneOrder.removeAll { $0 == deviceID }
    }

    static func destinations(allConnectedDeviceIDs: [String], excluding sourceDeviceID: String?) -> [String] {
        var seen = Set<String>()
        return allConnectedDeviceIDs.filter { deviceID in
            deviceID != sourceDeviceID && seen.insert(deviceID).inserted
        }
    }

    private mutating func nextRevision() -> UInt64 {
        revision &+= 1
        if revision == 0 { revision = 1 }
        return revision
    }

    @discardableResult
    private mutating func remember(changeID: String) -> Bool {
        guard !changeID.isEmpty, seenChangeIDs.insert(changeID).inserted else { return false }
        seenChangeIDOrder.append(changeID)
        if seenChangeIDOrder.count > seenCapacity {
            let overflow = seenChangeIDOrder.count - seenCapacity
            let expired = Array(seenChangeIDOrder.prefix(overflow))
            seenChangeIDOrder.removeFirst(overflow)
            for value in expired { seenChangeIDs.remove(value) }
        }
        return true
    }

}

/// A failed capture-free clipboard control socket must recover even when the
/// ADB topology itself did not change. Keep this policy independent from
/// screen-session reconnects: clipboard sync is expected to remain available
/// with every mirror window closed.
enum ClipboardSessionReconnectPolicy {
    private static let delays: [TimeInterval] = [1, 2, 5, 10, 30]

    static func delay(afterFailure attempt: Int) -> TimeInterval {
        delays[min(max(0, attempt), delays.count - 1)]
    }
}
