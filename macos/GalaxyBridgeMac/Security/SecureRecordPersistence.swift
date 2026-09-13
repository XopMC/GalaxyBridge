import CryptoKit
import Darwin
import Foundation

protocol SecureRecordPersistenceBackend: AnyObject {
    func upsert(service: String, account: String, data: Data) throws
    func read(service: String, account: String) throws -> Data?
    func accounts(service: String) throws -> [String]
    func delete(service: String, account: String) throws
}

enum SecureRecordBackendKind: Equatable {
    case localFile
    case dataProtectionKeychain
}

enum SecureRecordBackendFactory {
    static let internalBundleIdentifier = "com.xopmc.GalaxyBridge.internal"
    static let publicBundleIdentifier = "com.xopmc.GalaxyBridge"

    static func kind(bundleIdentifier: String?, distribution: String? = nil) -> SecureRecordBackendKind {
        if bundleIdentifier == internalBundleIdentifier { return .localFile }
        if bundleIdentifier == publicBundleIdentifier, distribution == "github-direct" { return .localFile }
        return .dataProtectionKeychain
    }

    static func make(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        distribution: String? = Bundle.main.object(forInfoDictionaryKey: "GalaxyBridgeDistribution") as? String,
        internalRootURL: URL? = nil,
        applicationSupportRootURL: URL? = nil,
        keychainBackend: @autoclosure () -> any SecureRecordPersistenceBackend
    ) -> any SecureRecordPersistenceBackend {
        if bundleIdentifier == internalBundleIdentifier {
            return LocalSecureRecordPersistenceBackend(rootURL: internalRootURL ?? defaultInternalRootURL())
        }
        if kind(bundleIdentifier: bundleIdentifier, distribution: distribution) == .localFile {
            // The explicit GitHub distribution has no Data Protection Keychain entitlement.
            // Select its isolated store before any operation; never fall back after an error.
            return LocalSecureRecordPersistenceBackend(
                rootURL: defaultDirectRootURL(applicationSupportRootURL: applicationSupportRootURL)
            )
        }
        return keychainBackend()
    }

    static func defaultDirectRootURL(applicationSupportRootURL: URL? = nil) -> URL {
        let base = applicationSupportRootURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("GalaxyBridge", isDirectory: true)
            .appendingPathComponent("DirectSecureRecords-v1", isDirectory: true)
    }

    static func defaultInternalRootURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["GALAXYBRIDGE_INTERNAL_RECORD_STORE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("GalaxyBridge", isDirectory: true)
            .appendingPathComponent("InternalSecureRecords-v1", isDirectory: true)
    }
}

final class LocalSecureRecordPersistenceBackend: SecureRecordPersistenceBackend {
    private struct Record: Codable {
        let version: Int
        let service: String
        let account: String
        let data: Data
    }

    private let rootURL: URL
    private let lock = NSLock()

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func upsert(service: String, account: String, data: Data) throws {
        try lock.withLock {
            try prepareRoot()
            let encoded = try JSONEncoder().encode(
                Record(version: 1, service: service, account: account, data: data)
            )
            try atomicWrite(encoded, to: recordURL(service: service, account: account))
        }
    }

    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            try prepareRoot()
            let url = recordURL(service: service, account: account)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let record = try decodeRecord(at: url)
            guard record.service == service, record.account == account else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return record.data
        }
    }

    func accounts(service: String) throws -> [String] {
        try lock.withLock {
            try prepareRoot()
            return try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "record" }
            .compactMap { url -> String? in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let record = try? decodeRecord(at: url),
                      record.version == 1,
                      record.service == service
                else { return nil }
                return record.account
            }
            .sorted()
        }
    }

    func delete(service: String, account: String) throws {
        try lock.withLock {
            try prepareRoot()
            let url = recordURL(service: service, account: account)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepareRoot() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, !isSymbolicLink(rootURL) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: UInt16(0o700))]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o700))],
            ofItemAtPath: rootURL.path
        )
    }

    private func recordURL(service: String, account: String) -> URL {
        let digest = SHA256.hash(data: Data("\(service)\u{0}\(account)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent("\(name).record", isDirectory: false)
    }

    private func decodeRecord(at url: URL) throws -> Record {
        guard !isSymbolicLink(url) else { throw CocoaError(.fileReadInvalidFileName) }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        shouldRemoveTemporary = false
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
