import CryptoKit
import Foundation

enum ApplicationIconCacheError: Error, Equatable {
    case invalidPNG
    case iconTooLarge
}

final class ApplicationIconCache: @unchecked Sendable {
    private let rootURL: URL
    private let retention: TimeInterval
    private let maximumEntries: Int
    private let maximumIconBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        rootURL: URL? = nil,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        maximumEntries: Int = 512,
        maximumIconBytes: Int = 4 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        precondition(retention > 0)
        precondition(maximumEntries > 0)
        precondition(maximumIconBytes >= 24)
        self.rootURL = try rootURL ?? Self.defaultRootURL()
        self.retention = retention
        self.maximumEntries = maximumEntries
        self.maximumIconBytes = maximumIconBytes
        self.now = now
        try FileManager.default.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func iconPNG(deviceID: String, packageName: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(deviceID: deviceID, packageName: packageName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modified = values.contentModificationDate,
              now().timeIntervalSince(modified) <= retention
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func store(_ iconPNG: Data, deviceID: String, packageName: String) throws {
        guard iconPNG.count <= maximumIconBytes else {
            throw ApplicationIconCacheError.iconTooLarge
        }
        guard Self.hasSafePNGHeader(iconPNG) else {
            throw ApplicationIconCacheError.invalidPNG
        }
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(deviceID: deviceID, packageName: packageName)
        try iconPNG.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: now()],
            ofItemAtPath: url.path
        )
        try pruneIfNeeded()
    }

    private static func hasSafePNGHeader(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24,
              Array(data.prefix(8)) == signature,
              Array(data[12 ..< 16]) == [0x49, 0x48, 0x44, 0x52]
        else { return false }
        let width = bigEndianUInt32(data, at: 16)
        let height = bigEndianUInt32(data, at: 20)
        return width > 0 && height > 0 && width <= 1_024 && height <= 1_024
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private func pruneIfNeeded() throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: keys).isRegularFile) == true
        }
        guard files.count > maximumEntries else { return }
        let sorted = files.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            if leftDate == rightDate { return left.lastPathComponent < right.lastPathComponent }
            return leftDate < rightDate
        }
        for url in sorted.prefix(files.count - maximumEntries) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(deviceID: String, packageName: String) -> URL {
        let digest = SHA256.hash(data: Data("\(deviceID)\u{0}\(packageName)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootURL.appendingPathComponent("\(digest).png", isDirectory: false)
    }

    private static func defaultRootURL() throws -> URL {
        try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("GalaxyBridge", isDirectory: true)
        .appendingPathComponent("ApplicationIcons-v1", isDirectory: true)
    }
}
