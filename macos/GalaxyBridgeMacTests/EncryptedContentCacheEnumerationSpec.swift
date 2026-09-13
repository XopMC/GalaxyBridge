import CryptoKit
import CSQLite
import Foundation

@main
enum EncryptedContentCacheEnumerationSpec {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyBridgeCacheEnumeration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("cache.sqlite3")
        let keyData = Data(repeating: 0x5a, count: 32)
        let cache = try EncryptedContentCache(url: databaseURL, keyData: keyData)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try cache.put(
            deviceID: "device:paired",
            namespace: .notifications,
            itemID: "notification-current",
            payload: Data([0x10, 0x11, 0x12]),
            now: now.addingTimeInterval(-60)
        )
        try cache.put(
            deviceID: "device:paired",
            namespace: .notifications,
            itemID: "notification-expired",
            payload: Data([0x20, 0x21, 0x22]),
            now: now.addingTimeInterval(-EncryptedContentCache.retention - 1)
        )
        try cache.put(
            deviceID: "device:other",
            namespace: .notifications,
            itemID: "notification-other-device",
            payload: Data([0x30, 0x31, 0x32]),
            now: now.addingTimeInterval(-30)
        )
        try cache.put(
            deviceID: "device:paired",
            namespace: .sms,
            itemID: "sms-current",
            payload: Data([0x40, 0x41, 0x42]),
            now: now.addingTimeInterval(-20)
        )

        var notifications = try cache.contents(
            deviceID: "device:paired",
            namespace: .notifications,
            now: now
        )
        precondition(notifications.map(\.itemID) == ["notification-current"])
        precondition(notifications[0].payload == Data([0x10, 0x11, 0x12]))
        let sms = try cache.contents(deviceID: "device:paired", namespace: .sms, now: now)
        precondition(sms.map(\.itemID) == ["sms-current"])

        let removedCount = try cache.remove(
            deviceID: "device:paired",
            namespace: .notifications,
            itemID: "notification-current"
        )
        precondition(removedCount == 1)
        notifications = try cache.contents(
            deviceID: "device:paired",
            namespace: .notifications,
            now: now
        )
        precondition(notifications.isEmpty)
        try cache.put(
            deviceID: "device:paired",
            namespace: .notifications,
            itemID: "notification-current",
            payload: Data([0x10, 0x11, 0x12]),
            now: now.addingTimeInterval(-60)
        )

        try cache.put(
            deviceID: "device:paired",
            namespace: .notifications,
            itemID: "notification-corrupt",
            payload: Data([0x50, 0x51, 0x52]),
            now: now.addingTimeInterval(-10)
        )
        try corruptPayload(databaseURL: databaseURL, itemID: "notification-corrupt")

        notifications = try cache.contents(
            deviceID: "device:paired",
            namespace: .notifications,
            now: now,
            pruneCorrupted: true
        )
        precondition(notifications.map(\.itemID) == ["notification-current"])
        let corruptCount = try countRows(databaseURL: databaseURL, itemID: "notification-corrupt")
        let healthyCount = try countRows(databaseURL: databaseURL, itemID: "notification-current")
        precondition(corruptCount == 0)
        precondition(healthyCount == 1)

        let revokedCount = try cache.revoke(deviceID: "device:paired")
        let revokedNotifications = try cache.contents(deviceID: "device:paired", namespace: .notifications, now: now)
        let revokedSMS = try cache.contents(deviceID: "device:paired", namespace: .sms, now: now)
        precondition(revokedCount == 2)
        precondition(revokedNotifications.isEmpty)
        precondition(revokedSMS.isEmpty)

        try assertIdentifiersAreNotStoredInPlaintext(databaseURL: databaseURL)

        let keylessRevokedCount = try EncryptedContentCache.revokeStoredContent(
            deviceID: "device:other",
            url: databaseURL
        )
        let otherNotifications = try cache.contents(
            deviceID: "device:other",
            namespace: .notifications,
            now: now
        )
        precondition(keylessRevokedCount == 1)
        precondition(otherNotifications.isEmpty)

        let recordRoot = root.appendingPathComponent("records", isDirectory: true)
        let recordBackend = LocalSecureRecordPersistenceBackend(rootURL: recordRoot)
        let persistedDatabaseURL = root.appendingPathComponent("persisted-cache.sqlite3")
        do {
            let persisted = try EncryptedContentCache(
                url: persistedDatabaseURL,
                recordBackend: recordBackend
            )
            try persisted.put(
                deviceID: "device:persisted",
                namespace: .clipboard,
                itemID: "clipboard-persisted",
                payload: Data("survives-rebuild".utf8),
                now: now
            )
        }
        let reopened = try EncryptedContentCache(
            url: persistedDatabaseURL,
            recordBackend: LocalSecureRecordPersistenceBackend(rootURL: recordRoot)
        )
        let persistedContent = try reopened.content(
            deviceID: "device:persisted",
            namespace: .clipboard,
            itemID: "clipboard-persisted",
            now: now
        )
        precondition(persistedContent?.payload == Data("survives-rebuild".utf8))
        let recordRootAttributes = try FileManager.default.attributesOfItem(atPath: recordRoot.path)
        precondition((recordRootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        print("Encrypted content cache enumeration regression passed.")
    }

    private static func corruptPayload(databaseURL: URL, itemID: String) throws {
        let database = try open(databaseURL)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(
            database,
            "UPDATE encrypted_content SET ciphertext = X'00' WHERE item_hash = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        bind(Data(SHA256.hash(data: Data(itemID.utf8))), at: 1, to: statement!)
        precondition(sqlite3_step(statement) == SQLITE_DONE)
    }

    private static func countRows(databaseURL: URL, itemID: String) throws -> Int {
        let database = try open(databaseURL)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM encrypted_content WHERE item_hash = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        bind(Data(SHA256.hash(data: Data(itemID.utf8))), at: 1, to: statement!)
        precondition(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func assertIdentifiersAreNotStoredInPlaintext(databaseURL: URL) throws {
        let bytes = try Data(contentsOf: databaseURL)
        for forbidden in ["notification-other-device", "device:other"] {
            precondition(bytes.range(of: Data(forbidden.utf8)) == nil)
        }
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else { throw NSError(domain: "EncryptedContentCacheEnumerationSpec", code: 1) }
        return database
    }

    private static func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
