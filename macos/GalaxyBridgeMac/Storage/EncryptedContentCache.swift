import CSQLite
import CryptoKit
import Foundation
import GalaxyBridgeCore
import Security

struct CachedContent: Sendable, Equatable {
    let payload: Data
    let createdAt: Date
    let expiresAt: Date
}

struct CachedContentRecord: Sendable, Equatable {
    let itemID: String
    let payload: Data
    let createdAt: Date
    let expiresAt: Date
}

final class EncryptedContentCache: @unchecked Sendable {
    enum Namespace: String, CaseIterable, Sendable {
        case notifications
        case sms
        case clipboard
    }

    static let retention: TimeInterval = 30 * 24 * 60 * 60
    private let database: OpaquePointer
    private let key: SymmetricKey
    private let lock = NSLock()

    init(
        url: URL? = nil,
        keyData: Data? = nil,
        recordBackend: (any SecureRecordPersistenceBackend)? = nil
    ) throws {
        if let keyData {
            guard keyData.count == 32 else { throw CacheError.invalidKey }
            key = SymmetricKey(data: keyData)
        } else {
            let backend = recordBackend ?? SecureRecordBackendFactory.make(
                keychainBackend: KeychainSecureRecordPersistenceBackend()
            )
            key = try Self.loadOrCreateKey(backend: backend)
        }
        let databaseURL = try url ?? Self.defaultDatabaseURL()
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw CacheError.sqlite("open")
        }
        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS encrypted_content (
                    device_hash BLOB NOT NULL,
                    namespace TEXT NOT NULL,
                    item_hash BLOB NOT NULL,
                    ciphertext BLOB NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(device_hash, namespace, item_hash)
                )
                """
            )
            try execute("CREATE INDEX IF NOT EXISTS encrypted_content_expiry ON encrypted_content(expires_at_ms)")
            if try !hasColumn("item_id_ciphertext", in: "encrypted_content") {
                try execute("ALTER TABLE encrypted_content ADD COLUMN item_id_ciphertext BLOB")
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func put(
        deviceID: String,
        namespace: Namespace,
        itemID: String,
        payload: Data,
        now: Date = Date(),
        retention: TimeInterval = EncryptedContentCache.retention
    ) throws {
        guard retention > 0, retention <= Self.retention else { throw CacheError.invalidRetention }
        let aad = authenticatedData(deviceID: deviceID, namespace: namespace, itemID: itemID)
        let ciphertext = try EncryptedPayload.seal(payload, using: key, authenticatedData: aad).combined
        let itemIDCiphertext = try EncryptedPayload.seal(
            Data(itemID.utf8),
            using: key,
            authenticatedData: itemIdentifierAuthenticatedData(deviceID: deviceID, namespace: namespace)
        ).combined
        try withStatement(
            """
            INSERT OR REPLACE INTO encrypted_content
            (device_hash, namespace, item_hash, ciphertext, created_at_ms, expires_at_ms, item_id_ciphertext)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            bind(hash(deviceID), at: 1, to: statement)
            bind(namespace.rawValue, at: 2, to: statement)
            bind(hash(itemID), at: 3, to: statement)
            bind(ciphertext, at: 4, to: statement)
            sqlite3_bind_int64(statement, 5, Int64(now.timeIntervalSince1970 * 1_000))
            sqlite3_bind_int64(statement, 6, Int64((now.timeIntervalSince1970 + retention) * 1_000))
            bind(itemIDCiphertext, at: 7, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    func content(
        deviceID: String,
        namespace: Namespace,
        itemID: String,
        now: Date = Date()
    ) throws -> CachedContent? {
        try withStatement(
            """
            SELECT ciphertext, created_at_ms, expires_at_ms
            FROM encrypted_content
            WHERE device_hash = ? AND namespace = ? AND item_hash = ? AND expires_at_ms > ?
            """
        ) { statement in
            bind(hash(deviceID), at: 1, to: statement)
            bind(namespace.rawValue, at: 2, to: statement)
            bind(hash(itemID), at: 3, to: statement)
            sqlite3_bind_int64(statement, 4, Int64(now.timeIntervalSince1970 * 1_000))
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw sqliteError() }
            let ciphertext = data(column: 0, from: statement)
            let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)) / 1_000)
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2)) / 1_000)
            let payload = try EncryptedPayload.open(
                SealedPayload(combined: ciphertext),
                using: key,
                authenticatedData: authenticatedData(deviceID: deviceID, namespace: namespace, itemID: itemID)
            )
            return CachedContent(payload: payload, createdAt: createdAt, expiresAt: expiresAt)
        }
    }

    /// Enumerates only live records for a known paired device. Item identifiers
    /// remain encrypted at rest; their hashes are used solely for lookup and
    /// integrity verification. A damaged row is isolated from healthy history.
    func contents(
        deviceID: String,
        namespace: Namespace,
        now: Date = Date(),
        pruneCorrupted: Bool = true
    ) throws -> [CachedContentRecord] {
        _ = try prune(now: now)
        var corruptItemHashes: [Data] = []
        let records: [CachedContentRecord] = try withStatement(
            """
            SELECT item_hash, item_id_ciphertext, ciphertext, created_at_ms, expires_at_ms
            FROM encrypted_content
            WHERE device_hash = ? AND namespace = ? AND expires_at_ms > ?
            ORDER BY created_at_ms DESC, item_hash ASC
            """
        ) { statement in
            bind(hash(deviceID), at: 1, to: statement)
            bind(namespace.rawValue, at: 2, to: statement)
            sqlite3_bind_int64(statement, 3, Int64(now.timeIntervalSince1970 * 1_000))
            var result: [CachedContentRecord] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw sqliteError() }
                let itemHash = data(column: 0, from: statement)
                do {
                    let itemIDCiphertext = data(column: 1, from: statement)
                    guard !itemIDCiphertext.isEmpty else { throw CacheError.corruptedRow }
                    let itemIDData = try EncryptedPayload.open(
                        SealedPayload(combined: itemIDCiphertext),
                        using: key,
                        authenticatedData: itemIdentifierAuthenticatedData(
                            deviceID: deviceID,
                            namespace: namespace
                        )
                    )
                    guard let itemID = String(data: itemIDData, encoding: .utf8),
                          !itemID.isEmpty,
                          hash(itemID) == itemHash
                    else { throw CacheError.corruptedRow }
                    let ciphertext = data(column: 2, from: statement)
                    let payload = try EncryptedPayload.open(
                        SealedPayload(combined: ciphertext),
                        using: key,
                        authenticatedData: authenticatedData(
                            deviceID: deviceID,
                            namespace: namespace,
                            itemID: itemID
                        )
                    )
                    result.append(
                        CachedContentRecord(
                            itemID: itemID,
                            payload: payload,
                            createdAt: Date(
                                timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3)) / 1_000
                            ),
                            expiresAt: Date(
                                timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4)) / 1_000
                            )
                        )
                    )
                } catch {
                    corruptItemHashes.append(itemHash)
                }
            }
            return result
        }
        if pruneCorrupted {
            for itemHash in corruptItemHashes {
                try delete(deviceID: deviceID, namespace: namespace, itemHash: itemHash)
            }
        }
        return records
    }

    @discardableResult
    func prune(now: Date = Date()) throws -> Int {
        try withStatement("DELETE FROM encrypted_content WHERE expires_at_ms <= ?") { statement in
            sqlite3_bind_int64(statement, 1, Int64(now.timeIntervalSince1970 * 1_000))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            return Int(sqlite3_changes(database))
        }
    }

    @discardableResult
    func revoke(deviceID: String) throws -> Int {
        try withStatement("DELETE FROM encrypted_content WHERE device_hash = ?") { statement in
            bind(hash(deviceID), at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            return Int(sqlite3_changes(database))
        }
    }

    @discardableResult
    func remove(deviceID: String, namespace: Namespace, itemID: String) throws -> Int {
        try withStatement(
            "DELETE FROM encrypted_content WHERE device_hash = ? AND namespace = ? AND item_hash = ?"
        ) { statement in
            bind(hash(deviceID), at: 1, to: statement)
            bind(namespace.rawValue, at: 2, to: statement)
            bind(hash(itemID), at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            return Int(sqlite3_changes(database))
        }
    }

    /// Deletes a revoked identity without loading the AES key. This keeps
    /// revocation effective even while the login Keychain is temporarily
    /// unavailable; only deterministic hashes are used in the SQL predicate.
    @discardableResult
    static func revokeStoredContent(deviceID: String, url: URL? = nil) throws -> Int {
        try deleteStoredContent(deviceID: deviceID, namespace: nil, itemID: nil, url: url)
    }

    /// Removes a tombstoned item without decrypting the database key.
    @discardableResult
    static func removeStoredContent(
        deviceID: String,
        namespace: Namespace,
        itemID: String,
        url: URL? = nil
    ) throws -> Int {
        try deleteStoredContent(
            deviceID: deviceID,
            namespace: namespace,
            itemID: itemID,
            url: url
        )
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError() }
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        try withStatement("PRAGMA table_info(\(table))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqlite3_column_text(statement, 1) else { continue }
                if String(cString: name) == column { return true }
            }
            return false
        }
    }

    private func delete(deviceID: String, namespace: Namespace, itemHash: Data) throws {
        try withStatement(
            "DELETE FROM encrypted_content WHERE device_hash = ? AND namespace = ? AND item_hash = ?"
        ) { statement in
            bind(hash(deviceID), at: 1, to: statement)
            bind(namespace.rawValue, at: 2, to: statement)
            bind(itemHash, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
        }
    }

    private func withStatement<Result>(
        _ sql: String,
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func data(column: Int32, from statement: OpaquePointer) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func authenticatedData(deviceID: String, namespace: Namespace, itemID: String) -> Data {
        Data("galaxybridge-cache-v1\0\(deviceID)\0\(namespace.rawValue)\0\(itemID)".utf8)
    }

    private func itemIdentifierAuthenticatedData(deviceID: String, namespace: Namespace) -> Data {
        Data("galaxybridge-cache-item-v1\0\(deviceID)\0\(namespace.rawValue)".utf8)
    }

    private func hash(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }

    private func sqliteError() -> CacheError {
        CacheError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static func defaultDatabaseURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("GalaxyBridge", isDirectory: true)
        .appendingPathComponent("cache.sqlite3")
    }

    private static func deleteStoredContent(
        deviceID: String,
        namespace: Namespace?,
        itemID: String?,
        url: URL?
    ) throws -> Int {
        let databaseURL = try url ?? defaultDatabaseURL()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return 0 }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw CacheError.sqlite("open for deletion")
        }
        defer { sqlite3_close(database) }

        let sql: String
        if namespace != nil, itemID != nil {
            sql = "DELETE FROM encrypted_content WHERE device_hash = ? AND namespace = ? AND item_hash = ?"
        } else {
            sql = "DELETE FROM encrypted_content WHERE device_hash = ?"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw CacheError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bindStatic(Data(SHA256.hash(data: Data(deviceID.utf8))), at: 1, to: statement)
        if let namespace, let itemID {
            sqlite3_bind_text(statement, 2, namespace.rawValue, -1, SQLITE_TRANSIENT)
            bindStatic(Data(SHA256.hash(data: Data(itemID.utf8))), at: 3, to: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CacheError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_changes(database))
    }

    private static func bindStatic(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }

    private static func loadOrCreateKey(
        backend: any SecureRecordPersistenceBackend
    ) throws -> SymmetricKey {
        if let data = try backend.read(service: keychainService, account: keychainAccount) {
            guard data.count == 32 else { throw CacheError.invalidKey }
            return SymmetricKey(data: data)
        }
        var data = Data(count: 32)
        let randomStatus = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw CacheError.keychain(randomStatus) }
        try backend.upsert(service: keychainService, account: keychainAccount, data: data)
        return SymmetricKey(data: data)
    }

    private static var keychainService: String {
        if Bundle.main.bundleIdentifier == SecureRecordBackendFactory.internalBundleIdentifier {
            return "com.xopmc.GalaxyBridge.internal.local-v1.cache"
        }
        return "com.xopmc.GalaxyBridge.cache"
    }
    private static let keychainAccount = "content-aes256-v1"
}

enum CacheError: Error, LocalizedError {
    case invalidRetention
    case invalidKey
    case corruptedRow
    case sqlite(String)
    case keychain(OSStatus)

    var errorDescription: String? { String(localized: "ERROR_LOCAL_HISTORY") }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
