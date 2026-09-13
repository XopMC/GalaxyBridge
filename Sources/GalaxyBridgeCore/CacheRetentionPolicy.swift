import Foundation

public struct CacheRetentionPolicy: Equatable, Sendable {
    public let retention: TimeInterval

    public init(retention: TimeInterval = 30 * 24 * 60 * 60) {
        precondition(retention >= 0)
        self.retention = retention
    }

    public func isExpired(createdAt: Date, now: Date) -> Bool {
        createdAt < now.addingTimeInterval(-retention)
    }
}
