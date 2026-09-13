import CryptoKit
import Foundation

public struct ClipboardItemIdentity: Hashable, Sendable {
    public let originDeviceID: UUID
    public let sequence: UInt64
    public let contentSHA256: Data

    public init(originDeviceID: UUID, sequence: UInt64, contentSHA256: Data) {
        self.originDeviceID = originDeviceID
        self.sequence = sequence
        self.contentSHA256 = contentSHA256
    }
}

public struct ClipboardLoopSuppressor: Sendable {
    private let localDeviceID: UUID
    private let capacity: Int
    private var nextSequence: UInt64 = 1
    private var seen = Set<ClipboardItemIdentity>()
    private var order: [ClipboardItemIdentity] = []

    public init(localDeviceID: UUID, capacity: Int = 256) {
        precondition(capacity > 0)
        self.localDeviceID = localDeviceID
        self.capacity = capacity
    }

    public mutating func markPublished(_ content: Data) -> ClipboardItemIdentity {
        let identity = ClipboardItemIdentity(
            originDeviceID: localDeviceID,
            sequence: nextSequence,
            contentSHA256: Data(SHA256.hash(data: content))
        )
        nextSequence &+= 1
        remember(identity)
        return identity
    }

    public mutating func shouldAccept(_ identity: ClipboardItemIdentity) -> Bool {
        guard identity.originDeviceID != localDeviceID, !seen.contains(identity) else {
            return false
        }
        remember(identity)
        return true
    }

    private mutating func remember(_ identity: ClipboardItemIdentity) {
        guard seen.insert(identity).inserted else { return }
        order.append(identity)
        if order.count > capacity {
            seen.remove(order.removeFirst())
        }
    }
}
