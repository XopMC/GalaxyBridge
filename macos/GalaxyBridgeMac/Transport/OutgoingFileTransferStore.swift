import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct OutgoingFileTransfer: Codable, Sendable {
    let id: String
    let deviceID: String
    let peerFingerprint: Data
    let relativeName: String
    let size: UInt64
    let mimeType: String
    let sha256: Data
    let directory: URL
    var cancelRequested = false
    var url: URL { directory.appendingPathComponent("payload") }

    func read(offset: UInt64, maximumLength: Int) throws -> Data {
        guard !cancelRequested else { throw CancellationError() }
        guard offset <= size, maximumLength > 0, maximumLength <= 1024 * 1024 else { throw OutgoingFileTransferError.invalid }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OutgoingFileTransferError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Int(min(UInt64(maximumLength), size - offset))) ?? Data()
        guard bytes.count == Int(min(UInt64(maximumLength), size - offset)) else { throw OutgoingFileTransferError.changed }
        return bytes
    }
}

extension OutgoingFileTransfer {
    private enum CodingKeys: String, CodingKey {
        case id, deviceID, peerFingerprint, relativeName, size, mimeType, sha256, directory, cancelRequested
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        peerFingerprint = try values.decode(Data.self, forKey: .peerFingerprint)
        relativeName = try values.decode(String.self, forKey: .relativeName)
        size = try values.decode(UInt64.self, forKey: .size)
        mimeType = try values.decode(String.self, forKey: .mimeType)
        sha256 = try values.decode(Data.self, forKey: .sha256)
        directory = try values.decode(URL.self, forKey: .directory)
        cancelRequested = try values.decodeIfPresent(Bool.self, forKey: .cancelRequested) ?? false
    }
}

enum OutgoingFileTransferError: Error, LocalizedError {
    case invalid, changed, storage
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "FILE_INVALID")
        case .changed: String(localized: "FILE_CONTENT_MISMATCH")
        case .storage: String(localized: "FILE_TRANSFER_FAILED")
        }
    }
}

/// Invoke on an IO worker. A transfer reads an immutable private snapshot,
/// never the user-selected pathname again; records survive normal application
/// exit and are only restored for the same authenticated peer key.
struct OutgoingFileTransferStore: Sendable {
    static let maximumSize: UInt64 = 10 * 1024 * 1024 * 1024
    static func peerFingerprint(identityKey: Data, tlsFingerprint: Data, pairedAt: Date) -> Data {
        var domain = Data("galaxybridge-outgoing-peer-v1\0".utf8)
        domain.append(identityKey); domain.append(tlsFingerprint)
        domain.append(Data(String(Int64(pairedAt.timeIntervalSince1970 * 1000)).utf8))
        return Data(SHA256.hash(data: domain))
    }
    let root: URL
    init(root: URL? = nil) {
        let app = Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal" ? "GalaxyBridgeInternal" : "GalaxyBridge"
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(app).appendingPathComponent("OutgoingTransfers")
    }

    func prepare(deviceID: String, peerFingerprint: Data, sourceURL: URL) throws -> OutgoingFileTransfer {
        try Task.checkCancellation()
        guard peerFingerprint.count == 32, Self.validName(sourceURL.lastPathComponent) else { throw OutgoingFileTransferError.invalid }
        try prepareRoot()
        let id = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(id)
        guard mkdir(directory.path, 0o700) == 0 else { throw OutgoingFileTransferError.storage }
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        let fd = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OutgoingFileTransferError.invalid }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        let before = try Stamp(fd)
        guard before.size <= Self.maximumSize else { throw OutgoingFileTransferError.invalid }
        let snapshot = directory.appendingPathComponent("payload")
        if fclonefileat(fd, AT_FDCWD, snapshot.path, 0) != 0 {
            let outputFD = open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard outputFD >= 0 else { throw OutgoingFileTransferError.storage }
            let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
            defer { try? output.close() }
            var copied: UInt64 = 0
            while copied < before.size {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: Int(min(1024 * 1024, before.size - copied))) ?? Data()
                guard !bytes.isEmpty else { throw OutgoingFileTransferError.changed }
                try output.write(contentsOf: bytes)
                copied += UInt64(bytes.count)
            }
            try output.synchronize()
        }
        guard try Stamp(fd) == before else { throw OutgoingFileTransferError.changed }
        guard chmod(snapshot.path, 0o400) == 0 else { throw OutgoingFileTransferError.storage }
        let digest = try Self.digest(snapshot, expectedSize: before.size)
        let transfer = OutgoingFileTransfer(id: id, deviceID: deviceID, peerFingerprint: peerFingerprint,
            relativeName: sourceURL.lastPathComponent, size: before.size,
            mimeType: UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            sha256: digest, directory: directory)
        let manifest = directory.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(transfer).write(to: manifest, options: .atomic)
        guard chmod(manifest.path, 0o600) == 0 else { throw OutgoingFileTransferError.storage }
        for file in [snapshot, manifest] {
            let syncFD = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard syncFD >= 0 else { throw OutgoingFileTransferError.storage }
            let result = fsync(syncFD); Darwin.close(syncFD)
            guard result == 0 else { throw OutgoingFileTransferError.storage }
        }
        try syncDirectory(directory)
        try syncDirectory(root)
        committed = true
        return transfer
    }

    struct PendingResult: Sendable {
        let transfers: [OutgoingFileTransfer]
        let rejectedCount: Int
    }

    func pending(deviceID: String, peerFingerprint: Data) throws -> PendingResult {
        guard FileManager.default.fileExists(atPath: root.path) else { return PendingResult(transfers: [], rejectedCount: 0) }
        try validateDirectory(root)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var result: [OutgoingFileTransfer] = []
        var rejectedCount = 0
        for directory in entries where UUID(uuidString: directory.lastPathComponent) != nil {
            try Task.checkCancellation()
            do {
                try validateDirectory(directory)
                let manifest = directory.appendingPathComponent("manifest.json")
                var info = stat()
                // An interrupted snapshot without a committed record is not resumable.
                guard lstat(manifest.path, &info) == 0 else { continue }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= 8192 else {
                    throw OutgoingFileTransferError.storage
                }
                let transfer = try JSONDecoder().decode(OutgoingFileTransfer.self, from: Data(contentsOf: manifest))
                guard transfer.id == directory.lastPathComponent,
                      transfer.directory.standardizedFileURL.path == directory.standardizedFileURL.path,
                      transfer.size <= Self.maximumSize, transfer.sha256.count == 32,
                      Self.validName(transfer.relativeName) else { throw OutgoingFileTransferError.invalid }
                guard transfer.deviceID == deviceID, transfer.peerFingerprint == peerFingerprint else { continue }
                if !transfer.cancelRequested {
                    guard try Self.digest(transfer.url, expectedSize: transfer.size) == transfer.sha256 else {
                        throw OutgoingFileTransferError.changed
                    }
                }
                result.append(transfer)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Preserve evidence and allow unrelated valid transfers to resume. A corrupt
                // manifest may not identify its peer, so this is a path-free aggregate count.
                rejectedCount += 1
            }
        }
        return PendingResult(transfers: result, rejectedCount: rejectedCount)
    }

    /// Call on an IO worker. A failed write must leave the caller's cancellation fence in
    /// place: durability can be uncertain after an atomic rename followed by fsync failure.
    func requestCancellation(_ transfer: OutgoingFileTransfer) throws -> OutgoingFileTransfer {
        guard UUID(uuidString: transfer.id) != nil,
              transfer.directory.standardizedFileURL.path == root.appendingPathComponent(transfer.id).standardizedFileURL.path
        else { throw OutgoingFileTransferError.invalid }
        try validateDirectory(root)
        try validateDirectory(transfer.directory)
        let manifest = transfer.directory.appendingPathComponent("manifest.json")
        let fd = open(manifest.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OutgoingFileTransferError.storage }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        let before = try Stamp(fd)
        guard before.size <= 8192 else { throw OutgoingFileTransferError.invalid }
        let bytes = try input.read(upToCount: 8193) ?? Data()
        var current = try JSONDecoder().decode(OutgoingFileTransfer.self, from: bytes)
        guard current.id == transfer.id, current.deviceID == transfer.deviceID,
              current.peerFingerprint == transfer.peerFingerprint, current.size == transfer.size,
              current.sha256 == transfer.sha256, current.relativeName == transfer.relativeName,
              current.mimeType == transfer.mimeType,
              current.directory.standardizedFileURL.path == transfer.directory.standardizedFileURL.path
        else { throw OutgoingFileTransferError.invalid }
        current.cancelRequested = true
        try JSONEncoder().encode(current).write(to: manifest, options: .atomic)
        guard chmod(manifest.path, 0o600) == 0 else { throw OutgoingFileTransferError.storage }
        let syncFD = open(manifest.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard syncFD >= 0 else { throw OutgoingFileTransferError.storage }
        let result = fsync(syncFD); Darwin.close(syncFD)
        guard result == 0 else { throw OutgoingFileTransferError.storage }
        try syncDirectory(transfer.directory)
        try syncDirectory(root)
        return current
    }

    func remove(_ transfer: OutgoingFileTransfer) throws {
        guard UUID(uuidString: transfer.id) != nil,
              transfer.directory.standardizedFileURL.path == root.appendingPathComponent(transfer.id).standardizedFileURL.path else {
            throw OutgoingFileTransferError.invalid
        }
        guard FileManager.default.fileExists(atPath: transfer.directory.path) else { return }
        try validateDirectory(root)
        try validateDirectory(transfer.directory)
        try FileManager.default.removeItem(at: transfer.directory)
        try syncDirectory(root)
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw OutgoingFileTransferError.storage }
        try validateDirectory(root)
    }
    private func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw OutgoingFileTransferError.storage }
    }
    private func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OutgoingFileTransferError.storage }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw OutgoingFileTransferError.storage }
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name.utf8.count <= 240
            && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func digest(_ url: URL, expectedSize: UInt64) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OutgoingFileTransferError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let before = try Stamp(fd)
        guard before.size == expectedSize else { throw OutgoingFileTransferError.changed }
        var hash = SHA256(), count: UInt64 = 0
        while count < expectedSize {
            try Task.checkCancellation()
            let data = try file.read(upToCount: Int(min(1024 * 1024, expectedSize - count))) ?? Data()
            guard !data.isEmpty else { throw OutgoingFileTransferError.changed }
            hash.update(data: data); count += UInt64(data.count)
        }
        guard try Stamp(fd) == before else { throw OutgoingFileTransferError.changed }
        return Data(hash.finalize())
    }
    private struct Stamp: Equatable {
        let device: Int32, inode: UInt64, size: UInt64, modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        init(_ fd: Int32) throws {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw OutgoingFileTransferError.invalid }
            device = info.st_dev; inode = info.st_ino; size = UInt64(info.st_size)
            modified = Int64(info.st_mtimespec.tv_sec); modifiedNS = Int64(info.st_mtimespec.tv_nsec)
            changed = Int64(info.st_ctimespec.tv_sec); changedNS = Int64(info.st_ctimespec.tv_nsec)
        }
    }
}
