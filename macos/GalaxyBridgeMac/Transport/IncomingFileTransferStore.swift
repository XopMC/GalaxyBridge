import CryptoKit
import Darwin
import Foundation

struct IncomingFileOwner: Hashable, Sendable {
    let deviceID: String
    let fingerprint: Data
    var storageKey: String {
        Data(SHA256.hash(data: Data(deviceID.utf8) + Data([0]) + fingerprint))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct IncomingFileManifest: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let size: UInt64
    let sha256: Data
}

struct IncomingFileReceipt: Sendable {
    let id: String
    var offset: UInt64 = 0
    var complete = false
    var failureReason = ""
    var publishedName = ""
    var publishedNow = false
}

/// Owns inbound files on a serial executor. Checkpoints acknowledge only durable
/// bytes; hard-link publication cannot replace an existing Downloads item.
actor IncomingFileTransferStore {
    // Hooks expose real filesystem boundaries to deterministic race tests; production
    // has no observer and never waits for test coordination.
    enum Boundary: Sendable { case hashedChunk(String), beforePublication(String), didPublish(String) }
    private final class AdmissionFence: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = Set<String>()
        private var revoked = Set<String>()
        func cancel(owner: String, id: String) {
            lock.lock(); defer { lock.unlock() }; cancelled.insert(owner + "/" + id)
        }
        func revoke(owner: String) {
            lock.lock(); defer { lock.unlock() }; revoked.insert(owner)
        }
        func check(owner: String, id: String) throws {
            lock.lock(); defer { lock.unlock() }; try checkLocked(owner: owner, id: id)
        }
        // The request and the actual link syscall share one linearization lock.
        // A request that returns before this section prevents publication.
        func publish(owner: String, id: String, _ operation: () throws -> Bool) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            try checkLocked(owner: owner, id: id)
            return try operation()
        }
        func committedCancellation(owner: String, id: String) {
            lock.lock(); defer { lock.unlock() }; cancelled.remove(owner + "/" + id)
        }
        private func checkLocked(owner: String, id: String) throws {
            if revoked.contains(owner) { throw Failure("owner_revocation_pending") }
            // An in-memory fence is deliberately not a terminal cancel receipt.
            if cancelled.contains(owner + "/" + id) { throw Failure("transfer_cancel_pending") }
        }
    }
    private nonisolated let admission = AdmissionFence()
    private let boundary: (@Sendable (Boundary) -> Void)?
    static let maximumSize: UInt64 = 10 * 1024 * 1024 * 1024
    private enum Phase: String, Codable { case receiving, publishing, complete, cancelled }
    private struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        init(_ fd: Int32) throws {
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
                  s.st_uid == geteuid(), s.st_size >= 0 else { throw Failure("transfer_document_missing") }
            device = s.st_dev; inode = s.st_ino
        }
    }
    private struct Record: Codable {
        var version = 1
        let owner: String
        let id: String
        var manifest: IncomingFileManifest?
        var identity: Identity?
        var phase: Phase
        var offset: UInt64 = 0
        var prefixHash = Data(SHA256.hash(data: Data()))
        var publishedName = ""
    }
    private struct Working {
        var record: Record
        var hash: SHA256
    }
    private struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
    private let downloads: URL
    private let root: URL
    private var working: [String: Working] = [:]
    private var stopped = false
    private var revokedOwners = Set<String>()
    private let fileManager = FileManager.default

    init(downloads: URL? = nil, profile: String? = nil, boundary: (@Sendable (Boundary) -> Void)? = nil) {
        self.boundary = boundary
        self.downloads = (downloads ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        let app = profile ?? (Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            ? "GalaxyBridgeInternal" : "GalaxyBridge")
        root = self.downloads.appendingPathComponent(".\(app)-Incoming")
    }

    nonisolated func requestCancellation(owner: IncomingFileOwner, id: String) {
        guard owner.fingerprint.count == 32, UUID(uuidString: id)?.uuidString.lowercased() == id else { return }
        admission.cancel(owner: owner.storageKey, id: id)
    }

    nonisolated func requestRevocation(owner: IncomingFileOwner) {
        guard owner.fingerprint.count == 32 else { return }
        admission.revoke(owner: owner.storageKey)
    }

    func manifest(owner: IncomingFileOwner, manifest: IncomingFileManifest) -> IncomingFileReceipt {
        perform(id: manifest.id) {
            try validate(owner, id: manifest.id)
            guard Self.validName(manifest.name), manifest.size <= Self.maximumSize,
                  manifest.sha256.count == 32 else { throw Failure("invalid_manifest") }
            try prepareDirectories(owner)
            let key = cacheKey(owner, manifest.id)
            if let existing = try read(owner, id: manifest.id) {
                guard existing.phase == .cancelled || existing.manifest == manifest else {
                    throw Failure("manifest_conflict")
                }
                switch existing.phase {
                case .cancelled: try removePayload(owner, existing); return receipt(existing)
                case .complete: try? removePayload(owner, existing); return receipt(existing)
                case .publishing: return try publish(owner, existing)
                case .receiving:
                    // Re-read the committed prefix at each new manifest, including
                    // reconnects. Never trust a cached hash across this boundary.
                    working[key] = try restore(owner, existing)
                    if existing.offset == manifest.size { return try publish(owner, existing) }
                    return receipt(existing)
                }
            }
            try admission.check(owner: owner.storageKey, id: manifest.id)
            guard try activeCount() < 8 else { throw Failure("transfer_capacity_exceeded") }
            let dir = directory(owner, manifest.id)
            if mkdir(dir.path, 0o700) != 0 {
                // An allocation interrupted before its first checkpoint is owned
                // by this exact UUID, but is not automatically adopted/deleted.
                throw Failure("checkpoint_unavailable")
            }
            let fd = open(dir.appendingPathComponent("payload").path,
                          O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure("storage_folder_unavailable") }
            defer { Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw Failure("storage_folder_unavailable") }
            let record = Record(owner: owner.storageKey, id: manifest.id, manifest: manifest,
                                identity: try Identity(fd), phase: .receiving)
            try save(owner, record)
            working[key] = Working(record: record, hash: SHA256())
            if manifest.size == 0 { return try publish(owner, record) }
            return receipt(record)
        }
    }

    func chunk(owner: IncomingFileOwner, id: String, offset: UInt64, bytes: Data) -> IncomingFileReceipt {
        perform(id: id) {
            try validate(owner, id: id)
            guard !bytes.isEmpty, bytes.count <= 1024 * 1024 else { throw Failure("invalid_chunk") }
            let key = cacheKey(owner, id)
            guard let record = try read(owner, id: id) else {
                throw Failure("unknown_transfer")
            }
            if record.phase == .cancelled { try removePayload(owner, record); return receipt(record) }
            if record.phase == .complete { try? removePayload(owner, record); return receipt(record) }
            if record.phase == .publishing { return try publish(owner, record) }
            try admission.check(owner: owner.storageKey, id: id)
            guard let manifest = record.manifest else { throw Failure("unknown_transfer") }
            guard offset <= manifest.size, UInt64(bytes.count) <= manifest.size - offset else {
                throw Failure("invalid_chunk")
            }
            var current: Working
            if let cached = working[key], cached.record.offset == record.offset,
               cached.record.identity == record.identity, cached.record.prefixHash == record.prefixHash {
                current = cached
            } else { current = try restore(owner, record) }
            let fd = try payloadFD(owner, record, write: true)
            defer { Darwin.close(fd) }
            if offset < record.offset {
                guard UInt64(bytes.count) <= record.offset - offset,
                      try readBytes(fd, offset: offset, count: bytes.count) == bytes else {
                    throw Failure("conflicting_duplicate")
                }
                return receipt(record)
            }
            guard offset == record.offset else { return receipt(record) }
            try writeBytes(fd, offset: offset, bytes: bytes)
            guard fsync(fd) == 0 else { throw Failure("storage_folder_unavailable") }
            current.hash.update(data: bytes)
            current.record.offset += UInt64(bytes.count)
            current.record.prefixHash = Data(current.hash.finalize())
            do { try save(owner, current.record) }
            catch { working.removeValue(forKey: key); throw error }
            working[key] = current
            if current.record.offset == manifest.size { return try publish(owner, current.record) }
            return receipt(current.record)
        }
    }

    func cancel(owner: IncomingFileOwner, id: String) -> IncomingFileReceipt {
        requestCancellation(owner: owner, id: id)
        return perform(id: id) {
            try validate(owner, id: id)
            try prepareDirectories(owner)
            var record: Record
            if let existing = try read(owner, id: id) {
                if existing.phase == .complete {
                    admission.committedCancellation(owner: owner.storageKey, id: id)
                    return receipt(existing)
                }
                if existing.phase == .publishing {
                    // A saved intent alone is not publication. Cancellation wins
                    // until the exact payload inode is visible at its final name.
                    if try isPublished(existing) { return try publish(owner, existing) }
                }
                record = existing
            } else {
                _ = try activeCount()
                let dir = directory(owner, id)
                guard mkdir(dir.path, 0o700) == 0 else { throw Failure("checkpoint_unavailable") }
                record = Record(owner: owner.storageKey, id: id, phase: .cancelled)
            }
            record.phase = .cancelled
            try save(owner, record)
            admission.committedCancellation(owner: owner.storageKey, id: id)
            working.removeValue(forKey: cacheKey(owner, id))
            try removePayload(owner, record)
            return receipt(record)
        }
    }

    func shutdown() { stopped = true; working.removeAll() }

    func revoke(owner: IncomingFileOwner) throws {
        requestRevocation(owner: owner)
        guard owner.fingerprint.count == 32 else { throw Failure("invalid_manifest") }
        revokedOwners.insert(owner.storageKey)
        working = working.filter { !$0.key.hasPrefix(owner.storageKey + "/") }
        let directory = root.appendingPathComponent(owner.storageKey)
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return }; throw Failure("storage_folder_unavailable")
        }
        try validateDirectory(root)
        try validateDirectory(directory)
        // Only private staging/checkpoints are removed. Any published Downloads
        // hard link remains the user's file and is never a revocation target.
        try fileManager.removeItem(at: directory)
        try syncDirectory(root)
    }

    private func perform(id: String, _ operation: () throws -> IncomingFileReceipt) -> IncomingFileReceipt {
        do {
            guard !stopped else { throw Failure("receiver_stopped") }
            return try operation()
        } catch let failure as Failure {
            return IncomingFileReceipt(id: id, failureReason: failure.reason)
        } catch { return IncomingFileReceipt(id: id, failureReason: "storage_folder_unavailable") }
    }

    private func validate(_ owner: IncomingFileOwner, id: String) throws {
        guard !revokedOwners.contains(owner.storageKey) else { throw Failure("owner_revoked") }
        guard !owner.deviceID.isEmpty, owner.deviceID.utf8.count <= 128, owner.fingerprint.count == 32,
              let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw Failure("invalid_manifest")
        }
    }
    private func cacheKey(_ owner: IncomingFileOwner, _ id: String) -> String { owner.storageKey + "/" + id }
    private func directory(_ owner: IncomingFileOwner, _ id: String) -> URL {
        root.appendingPathComponent(owner.storageKey).appendingPathComponent(id)
    }
    private func prepareDirectories(_ owner: IncomingFileOwner) throws {
        var s = stat()
        guard lstat(downloads.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == geteuid() else {
            throw Failure("storage_folder_unavailable")
        }
        for dir in [root, root.appendingPathComponent(owner.storageKey)] {
            if mkdir(dir.path, 0o700) != 0 && errno != EEXIST { throw Failure("storage_folder_unavailable") }
            try validateDirectory(dir)
            try syncDirectory(dir.deletingLastPathComponent())
        }
    }
    private func validateDirectory(_ url: URL) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == geteuid(),
              s.st_mode & 0o077 == 0,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw Failure("storage_folder_unavailable")
        }
    }
    private func read(_ owner: IncomingFileOwner, id: String) throws -> Record? {
        let dir = directory(owner, id)
        var s = stat()
        guard lstat(dir.path, &s) == 0 else {
            if errno == ENOENT { return nil }; throw Failure("checkpoint_unavailable")
        }
        try validateDirectory(root)
        try validateDirectory(dir.deletingLastPathComponent())
        try validateDirectory(dir)
        let fd = open(dir.appendingPathComponent("record.json").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("checkpoint_unavailable") }
        defer { Darwin.close(fd) }
        _ = try Identity(fd)
        guard fstat(fd, &s) == 0, s.st_size <= 8192 else { throw Failure("checkpoint_unavailable") }
        let bytes = try readBytes(fd, offset: 0, count: Int(s.st_size))
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard record.version == 1, record.id == id, record.owner == owner.storageKey,
              validRecord(record) else {
            throw Failure("checkpoint_unavailable")
        }
        // Retry any previous rename whose directory fsync failed before its ACK.
        try syncDirectory(dir)
        try syncDirectory(dir.deletingLastPathComponent())
        return record
    }
    private func save(_ owner: IncomingFileOwner, _ record: Record) throws {
        let dir = directory(owner, record.id)
        try validateDirectory(dir)
        let temporary = dir.appendingPathComponent("record-" + UUID().uuidString.lowercased() + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("checkpoint_unavailable") }
        defer { Darwin.close(fd); _ = unlink(temporary.path) }
        try writeBytes(fd, offset: 0, bytes: JSONEncoder().encode(record))
        guard fsync(fd) == 0, rename(temporary.path, dir.appendingPathComponent("record.json").path) == 0 else {
            throw Failure("checkpoint_unavailable")
        }
        try syncDirectory(dir)
        try syncDirectory(dir.deletingLastPathComponent())
    }
    private func payloadFD(_ owner: IncomingFileOwner, _ record: Record, write: Bool) throws -> Int32 {
        try validateDirectory(directory(owner, record.id))
        let fd = open(directory(owner, record.id).appendingPathComponent("payload").path,
                      (write ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("transfer_document_missing") }
        do {
            guard try Identity(fd) == record.identity else { throw Failure("transfer_document_missing") }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func restore(_ owner: IncomingFileOwner, _ record: Record, alreadyPublished: Bool = false) throws -> Working {
        if !alreadyPublished { try admission.check(owner: owner.storageKey, id: record.id) }
        let mayRollback = record.phase == .receiving
        let fd = try payloadFD(owner, record, write: mayRollback)
        defer { Darwin.close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_size >= 0, UInt64(s.st_size) >= record.offset else {
            throw Failure("checkpoint_prefix_mismatch")
        }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < record.offset {
            if !alreadyPublished { try admission.check(owner: owner.storageKey, id: record.id) }
            let bytes = try readBytes(fd, offset: offset, count: Int(min(1024 * 1024, record.offset - offset)))
            hash.update(data: bytes); offset += UInt64(bytes.count)
            boundary?(.hashedChunk(record.id))
        }
        if !alreadyPublished { try admission.check(owner: owner.storageKey, id: record.id) }
        guard Data(hash.finalize()) == record.prefixHash else { throw Failure("checkpoint_prefix_mismatch") }
        if UInt64(s.st_size) > record.offset {
            // A publishing payload may already be hard-linked into Downloads.
            // Recovery must never truncate user-visible data, including a tail
            // appended by the user after a post-link process crash.
            guard mayRollback, s.st_nlink == 1 else { throw Failure("checkpoint_prefix_mismatch") }
            guard ftruncate(fd, off_t(record.offset)) == 0, fsync(fd) == 0 else {
                throw Failure("storage_folder_unavailable")
            }
        }
        return Working(record: record, hash: hash)
    }
    private func publish(_ owner: IncomingFileOwner, _ initial: Record) throws -> IncomingFileReceipt {
        var record = initial
        guard let manifest = record.manifest, record.offset == manifest.size,
              record.prefixHash == manifest.sha256 else { throw Failure("sha256_mismatch") }
        let payload = directory(owner, record.id).appendingPathComponent("payload")
        let fd = try payloadFD(owner, record, write: false)
        defer { Darwin.close(fd) }
        // Verify the actual complete file even in the same process: incremental
        // state must not hide an in-place change to previously acknowledged bytes.
        let alreadyPublished = try record.phase == .publishing && isPublished(record)
        _ = try restore(owner, record, alreadyPublished: alreadyPublished)
        var suffix = 0
        var linkedNow = false
        while !alreadyPublished && suffix < 10000 {
            let name = record.publishedName.isEmpty ? Self.collisionName(manifest.name, suffix: suffix) : record.publishedName
            guard Self.validName(name) else { throw Failure("destination_exists") }
            // The private staging directory is never a publication destination,
            // even if it is temporarily missing during recovery.
            if [root.lastPathComponent, ".GalaxyBridge-Incoming", ".GalaxyBridgeInternal-Incoming"].contains(name) {
                suffix += 1; record.publishedName = ""; continue
            }
            let destination = downloads.appendingPathComponent(name)
            record.phase = .publishing; record.publishedName = name
            try save(owner, record)
            boundary?(.beforePublication(record.id))
            let linked = try admission.publish(owner: owner.storageKey, id: record.id) {
                if link(payload.path, destination.path) == 0 { return true }
                guard errno == EEXIST else { throw Failure("storage_folder_unavailable") }
                return false
            }
            if linked {
                linkedNow = true
                boundary?(.didPublish(record.id))
                break
            }
            let existing = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if existing >= 0 {
                let identity = try? Identity(existing); Darwin.close(existing)
                if identity == record.identity { break }
            }
            suffix += 1; record.publishedName = ""
        }
        guard suffix < 10000 else { throw Failure("destination_exists") }
        try syncDirectory(downloads)
        record.phase = .complete
        try save(owner, record)
        admission.committedCancellation(owner: owner.storageKey, id: record.id)
        working.removeValue(forKey: cacheKey(owner, record.id))
        // Completion remains durable even if cleanup fails; a replay retries it.
        try removePayload(owner, record)
        var result = receipt(record)
        result.publishedNow = linkedNow
        return result
    }
    private func removePayload(_ owner: IncomingFileOwner, _ record: Record) throws {
        let path = directory(owner, record.id).appendingPathComponent("payload").path
        var s = stat()
        if lstat(path, &s) != 0 {
            if errno == ENOENT { return }; throw Failure("storage_folder_unavailable")
        }
        guard s.st_mode & S_IFMT == S_IFREG, let identity = record.identity,
              s.st_dev == identity.device, s.st_ino == identity.inode else {
            throw Failure("transfer_document_missing")
        }
        guard unlink(path) == 0 else { throw Failure("storage_folder_unavailable") }
        try syncDirectory(directory(owner, record.id))
    }
    private func receipt(_ record: Record) -> IncomingFileReceipt {
        IncomingFileReceipt(id: record.id, offset: record.offset, complete: record.phase == .complete,
            failureReason: record.phase == .cancelled ? "transfer_cancelled" : "",
            publishedName: record.phase == .complete ? record.publishedName : "")
    }
    private func activeCount() throws -> Int {
        var active = 0, metadataBytes = 0
        for ownerDir in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try validateDirectory(ownerDir)
            for dir in try fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil) {
                try validateDirectory(dir)
                let url = dir.appendingPathComponent("record.json")
                var s = stat()
                if lstat(url.path, &s) != 0 { active += 1; continue }
                guard s.st_mode & S_IFMT == S_IFREG, s.st_size >= 0, s.st_size <= 8192 else {
                    throw Failure("checkpoint_unavailable")
                }
                metadataBytes += Int(s.st_size)
                guard metadataBytes <= 64 * 1024 * 1024 else { throw Failure("transfer_capacity_exceeded") }
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
                guard record.version == 1, record.id == dir.lastPathComponent,
                      record.owner == ownerDir.lastPathComponent, validRecord(record) else {
                    throw Failure("checkpoint_unavailable")
                }
                if record.phase == .receiving || record.phase == .publishing { active += 1 }
            }
        }
        return active
    }
    private func validRecord(_ record: Record) -> Bool {
        guard record.prefixHash.count == 32,
              UUID(uuidString: record.id)?.uuidString.lowercased() == record.id else { return false }
        guard let manifest = record.manifest else {
            return record.phase == .cancelled && record.identity == nil && record.offset == 0
                && record.publishedName.isEmpty && record.prefixHash == Data(SHA256.hash(data: Data()))
        }
        guard manifest.id == record.id, Self.validName(manifest.name), manifest.size <= Self.maximumSize,
              manifest.sha256.count == 32, record.offset <= manifest.size, record.identity != nil else { return false }
        switch record.phase {
        case .receiving: return record.publishedName.isEmpty
        case .publishing, .complete:
            return record.offset == manifest.size && record.prefixHash == manifest.sha256
                && Self.validName(record.publishedName)
        case .cancelled: return record.publishedName.isEmpty || Self.validName(record.publishedName)
        }
    }
    private func isPublished(_ record: Record) throws -> Bool {
        guard Self.validName(record.publishedName), let identity = record.identity else { return false }
        var info = stat()
        if lstat(downloads.appendingPathComponent(record.publishedName).path, &info) != 0 {
            if errno == ENOENT { return false }; throw Failure("storage_folder_unavailable")
        }
        return info.st_mode & S_IFMT == S_IFREG && info.st_dev == identity.device && info.st_ino == identity.inode
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("storage_folder_unavailable") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw Failure("storage_folder_unavailable") }
    }
    private func readBytes(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count), done = 0
        try data.withUnsafeMutableBytes { bytes in
            while done < count {
                let n = pread(fd, bytes.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure("transfer_document_missing") }
                done += n
            }
        }
        return data
    }
    private func writeBytes(_ fd: Int32, offset: UInt64, bytes: Data) throws {
        var done = 0
        try bytes.withUnsafeBytes { raw in
            while done < bytes.count {
                let n = pwrite(fd, raw.baseAddress!.advanced(by: done), bytes.count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure("storage_folder_unavailable") }
                done += n
            }
        }
    }
    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".."
            && name.utf8.count <= 255 && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private static func collisionName(_ name: String, suffix: Int) -> String {
        guard suffix > 0 else { return name }
        let url = URL(fileURLWithPath: name), ext = url.pathExtension
        let stem = ext.isEmpty ? name : url.deletingPathExtension().lastPathComponent
        let marker = " (\(suffix))"
        let extensionSuffix = ext.isEmpty ? "" : "." + ext
        let available = 255 - marker.utf8.count
        // Preserve the extension when it leaves room for at least one stem scalar.
        // Unusually long extensions fall back to truncating the original name.
        if extensionSuffix.utf8.count + (stem.unicodeScalars.first?.utf8.count ?? 1) <= available {
            return utf8Prefix(stem, maximum: available - extensionSuffix.utf8.count) + marker + extensionSuffix
        }
        return utf8Prefix(name, maximum: available) + marker
    }
    private static func utf8Prefix(_ value: String, maximum: Int) -> String {
        var result = String.UnicodeScalarView(), used = 0
        for scalar in value.unicodeScalars {
            guard used + scalar.utf8.count <= maximum else { break }
            result.append(scalar); used += scalar.utf8.count
        }
        return String(result)
    }
}
