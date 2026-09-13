import Foundation

/// Runs only on the cache worker. A failed live handle must not skip the keyless path.
enum NotificationCacheRemovalAttempt {
    @discardableResult
    static func perform(live: (() throws -> Int)?, keyless: () throws -> Int) -> Bool {
        if let live, (try? live()) != nil { return true }
        return (try? keyless()) != nil
    }
}
