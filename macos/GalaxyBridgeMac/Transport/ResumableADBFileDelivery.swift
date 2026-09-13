import CryptoKit
import Darwin
import Foundation

/// This scope must come from the authenticated peer binding and Android user,
/// never a model name, IP address, or unverified ADB serial.
struct ADBFileDeliveryPeer: Equatable, Sendable {
    let identitySHA256: String
    let androidUserID: UInt32
    var owner: String {
        SHA256.hash(data: Data("galaxybridge-delivery-v1\u{0}\(identitySHA256)\u{0}\(androidUserID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
struct ADBFileDeliveryManifest: Codable, Equatable, Sendable {
    let transferID: String
    let owner: String
    let name: String
    let size: UInt64
    let sha256: String
    enum CodingKeys: String, CodingKey { case transferID = "transfer_id", owner, name, size, sha256 }
}
struct PreparedADBFileDelivery: Codable, Sendable {
    let manifest: ADBFileDeliveryManifest
    let snapshotURL: URL
    var recordURL: URL { snapshotURL.deletingLastPathComponent().appendingPathComponent("manifest.json") }
}
enum ADBFileDeliveryFailure: Error, Equatable {
    case invalidSource, sourceChanged, invalidManifest, peerChanged, interrupted, cancelled
    case invalidResponse, remote(String), processFailure, unsafeStateDirectory
}
enum ADBFileDeliveryProgress: Equatable, Sendable {
    case preparing(UInt64, UInt64)
    case reconciling(UInt64)
    case sending(UInt64, UInt64)
    case verifying(UInt64, UInt64)
    case completed
}
final class ADBFileDeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ADBFileDeliveryFailure.cancelled }
    }
}

/// Binary-safe, bounded process boundary. Implementations may invoke a pinned
/// receiver through verified `adb shell -T`, or a real local helper in fixtures.
protocol ADBFileDeliveryChannel: AnyObject {
    func write(_ data: Data, cancellation: ADBFileDeliveryCancellation) throws
    func readLine(cancellation: ADBFileDeliveryCancellation) throws -> Data
    func close()
}

/// Synchronous IO worker API: invoke from a dedicated off-main task. Transport
/// failure pauses; retain PreparedADBFileDelivery and call deliver again using
/// the same ID after revalidating the peer/ADB route. There is no retry loop.
enum ResumableADBFileDelivery {
    static let maximumSize: UInt64 = 10 * 1024 * 1024 * 1024
    static let chunkSize = 1024 * 1024
    typealias Progress = (ADBFileDeliveryProgress) -> Void

    static func prepare(sourceURL: URL, stateDirectory: URL, peer: ADBFileDeliveryPeer,
                        destinationName: String? = nil,
                        cancellation: ADBFileDeliveryCancellation,
                        progress: Progress = { _ in }) throws -> PreparedADBFileDelivery {
        try cancellation.check()
        guard isHex(peer.identitySHA256, count: 64) else { throw ADBFileDeliveryFailure.peerChanged }
        try privateDirectory(stateDirectory)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = stateDirectory.appendingPathComponent(id, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw ADBFileDeliveryFailure.unsafeStateDirectory }
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let source = try openSource(sourceURL)
        defer { try? source.close() }
        let before = try stamp(source)
        guard before.size <= maximumSize else { throw ADBFileDeliveryFailure.invalidSource }
        let snapshot = directory.appendingPathComponent("source.snapshot")
        // APFS clone is a coherent, cheap source view. Other volumes use a
        // bounded copy of the pinned descriptor, with change detection.
        if fclonefileat(source.fileDescriptor, AT_FDCWD, snapshot.path, 0) != 0 {
            let fd = open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ADBFileDeliveryFailure.invalidSource }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? output.close() }
            var copied: UInt64 = 0
            while copied < before.size {
                try cancellation.check()
                let bytes = try source.read(upToCount: Int(min(UInt64(chunkSize), before.size - copied))) ?? Data()
                guard !bytes.isEmpty else { throw ADBFileDeliveryFailure.sourceChanged }
                try output.write(contentsOf: bytes); copied += UInt64(bytes.count)
                progress(.preparing(copied, before.size))
            }
            try output.synchronize()
        }
        guard try stamp(source) == before else { throw ADBFileDeliveryFailure.sourceChanged }
        let view = try openSource(snapshot)
        defer { try? view.close() }
        let snapshotStamp = try stamp(view)
        guard snapshotStamp.size == before.size else { throw ADBFileDeliveryFailure.sourceChanged }
        let (digest, _) = try hash(view, size: before.size, prefix: 0, cancellation: cancellation, progress: progress)
        guard try stamp(view) == snapshotStamp else { throw ADBFileDeliveryFailure.sourceChanged }
        guard fsync(view.fileDescriptor) == 0 else { throw ADBFileDeliveryFailure.invalidSource }
        guard chmod(snapshot.path, 0o400) == 0 else { throw ADBFileDeliveryFailure.invalidSource }
        let manifest = ADBFileDeliveryManifest(transferID: id, owner: peer.owner,
            name: destinationName ?? sourceURL.lastPathComponent, size: before.size, sha256: digest)
        try validate(manifest)
        let prepared = PreparedADBFileDelivery(manifest: manifest, snapshotURL: snapshot)
        try JSONEncoder().encode(prepared).write(to: prepared.recordURL, options: .atomic)
        let record = try FileHandle(forWritingTo: prepared.recordURL)
        try record.synchronize(); try record.close()
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else { throw ADBFileDeliveryFailure.unsafeStateDirectory }
        defer { Darwin.close(dirFD) }
        guard fsync(dirFD) == 0 else { throw ADBFileDeliveryFailure.unsafeStateDirectory }
        retained = true
        return prepared
    }

    static func load(recordURL: URL) throws -> PreparedADBFileDelivery {
        let record = try openSource(recordURL)
        defer { try? record.close() }
        let data = try record.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw ADBFileDeliveryFailure.invalidManifest }
        let prepared = try JSONDecoder().decode(PreparedADBFileDelivery.self, from: data)
        try validate(prepared.manifest)
        guard prepared.snapshotURL.standardizedFileURL == recordURL.deletingLastPathComponent().appendingPathComponent("source.snapshot").standardizedFileURL,
              recordURL.deletingLastPathComponent().lastPathComponent == prepared.manifest.transferID else {
            throw ADBFileDeliveryFailure.invalidManifest
        }
        return prepared
    }

    static func deliver(_ prepared: PreparedADBFileDelivery, peer: ADBFileDeliveryPeer,
                        cancellation: ADBFileDeliveryCancellation,
                        openChannel: () throws -> any ADBFileDeliveryChannel,
                        progress: Progress = { _ in }) throws {
        try validate(prepared.manifest)
        guard peer.owner == prepared.manifest.owner else { throw ADBFileDeliveryFailure.peerChanged }
        try cancellation.check()
        let wire = try Wire(channel: openChannel(), manifest: prepared.manifest, cancellation: cancellation)
        defer { wire.channel.close() }
        let status = try wire.command(op: "begin", extra: ["manifest": object(prepared.manifest)]) {
            progress(.reconciling($0))
        }
        if status.complete { progress(.completed); return }
        guard !status.cancelled else { throw ADBFileDeliveryFailure.cancelled }
        let source = try openSource(prepared.snapshotURL)
        defer { try? source.close() }
        let before = try stamp(source)
        guard before.size == prepared.manifest.size else { throw ADBFileDeliveryFailure.sourceChanged }
        let (fullHash, prefixHash) = try hash(source, size: before.size, prefix: status.offset,
                                             cancellation: cancellation, progress: progress)
        guard fullHash == prepared.manifest.sha256, hex(prefixHash) == status.prefixSHA256,
              try stamp(source) == before else { throw ADBFileDeliveryFailure.sourceChanged }
        var prefix = prefixHash
        var offset = status.offset
        try source.seek(toOffset: offset)
        progress(.sending(offset, before.size))
        while offset < before.size {
            try cancellation.check()
            guard try stamp(source) == before else { throw ADBFileDeliveryFailure.sourceChanged }
            let bytes = try source.read(upToCount: Int(min(UInt64(chunkSize), before.size - offset))) ?? Data()
            guard !bytes.isEmpty else { throw ADBFileDeliveryFailure.sourceChanged }
            prefix.update(data: bytes)
            let ack = try wire.command(op: "append", extra: ["offset": offset, "length": bytes.count,
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()], payload: bytes) { _ in }
            let next = offset + UInt64(bytes.count)
            guard !ack.complete, !ack.cancelled, ack.offset == next, ack.prefixSHA256 == hex(prefix) else {
                throw ADBFileDeliveryFailure.invalidResponse
            }
            offset = ack.offset; progress(.sending(offset, before.size))
        }
        guard try stamp(source) == before else { throw ADBFileDeliveryFailure.sourceChanged }
        let completed = try wire.command(op: "commit") { progress(.verifying($0, before.size)) }
        guard completed.complete else { throw ADBFileDeliveryFailure.invalidResponse }
        progress(.completed)
    }

    /// Explicit remote cancellation is separate from local pause. Offline or
    /// interrupted cancellation remains unconfirmed; callers retain the record.
    static func cancelRemote(_ prepared: PreparedADBFileDelivery, peer: ADBFileDeliveryPeer,
                             cancellation: ADBFileDeliveryCancellation,
                             openChannel: () throws -> any ADBFileDeliveryChannel) throws -> Bool {
        try validate(prepared.manifest)
        guard peer.owner == prepared.manifest.owner else { throw ADBFileDeliveryFailure.peerChanged }
        try cancellation.check()
        let wire = try Wire(channel: openChannel(), manifest: prepared.manifest, cancellation: cancellation)
        defer { wire.channel.close() }
        let status = try wire.command(op: "begin", extra: ["manifest": object(prepared.manifest)]) { _ in }
        if status.complete { return false } // Commit won; preserve the user's final file.
        let cancelled = try wire.command(op: "cancel") { _ in }
        guard cancelled.cancelled || cancelled.complete else { throw ADBFileDeliveryFailure.invalidResponse }
        return cancelled.cancelled
    }

    private static func validate(_ manifest: ADBFileDeliveryManifest) throws {
        guard isHex(manifest.transferID, count: 32), isHex(manifest.owner, count: 64), isHex(manifest.sha256, count: 64),
              manifest.size <= maximumSize, !manifest.name.isEmpty, manifest.name.utf8.count <= 240,
              ![".", ".."].contains(manifest.name), !manifest.name.contains("/"), !manifest.name.contains("\\"),
              !manifest.name.hasPrefix(".galaxybridge-"),
              !manifest.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ADBFileDeliveryFailure.invalidManifest
        }
    }
    private static func object(_ manifest: ADBFileDeliveryManifest) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
    }
    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func hex(_ digest: SHA256) -> String { digest.finalize().map { String(format: "%02x", $0) }.joined() }
    private static func hash(_ source: FileHandle, size: UInt64, prefix: UInt64,
                             cancellation: ADBFileDeliveryCancellation, progress: Progress) throws -> (String, SHA256) {
        try source.seek(toOffset: 0)
        var full = SHA256(), prefixHash = SHA256(), offset: UInt64 = 0
        while offset < size {
            try cancellation.check()
            let bytes = try source.read(upToCount: Int(min(UInt64(chunkSize), size - offset))) ?? Data()
            guard !bytes.isEmpty else { throw ADBFileDeliveryFailure.sourceChanged }
            full.update(data: bytes)
            if offset < prefix { prefixHash.update(data: bytes.prefix(Int(min(UInt64(bytes.count), prefix - offset)))) }
            offset += UInt64(bytes.count); progress(.preparing(offset, size))
        }
        return (hex(full), prefixHash)
    }
    private struct Stamp: Equatable {
        let device: Int32, inode: UInt64, size: UInt64, modified: Int64, modifiedNS: Int64
    }
    private static func stamp(_ file: FileHandle) throws -> Stamp {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw ADBFileDeliveryFailure.invalidSource
        }
        return Stamp(device: info.st_dev, inode: info.st_ino, size: UInt64(info.st_size),
                     modified: Int64(info.st_mtimespec.tv_sec), modifiedNS: Int64(info.st_mtimespec.tv_nsec))
    }
    private static func openSource(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ADBFileDeliveryFailure.invalidSource }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private static func privateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw ADBFileDeliveryFailure.unsafeStateDirectory }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw ADBFileDeliveryFailure.unsafeStateDirectory }
    }

    private struct Status: Decodable {
        let offset: UInt64, prefixSHA256: String, complete: Bool, cancelled: Bool
        enum CodingKeys: String, CodingKey { case offset, prefixSHA256 = "prefix_sha256", complete, cancelled }
    }
    private struct Response: Decodable {
        let kind: String, sessionID: String, requestID: UInt64
        let status: Status?
        let bytes: UInt64?
        let code: String?
        enum CodingKeys: String, CodingKey { case kind, sessionID = "session_id", requestID = "request_id", status, bytes, code }
    }
    private final class Wire {
        let channel: any ADBFileDeliveryChannel
        let manifest: ADBFileDeliveryManifest
        let cancellation: ADBFileDeliveryCancellation
        let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var sequence: UInt64 = 0
        init(channel: any ADBFileDeliveryChannel, manifest: ADBFileDeliveryManifest, cancellation: ADBFileDeliveryCancellation) {
            self.channel = channel; self.manifest = manifest; self.cancellation = cancellation
        }
        func command(op: String, extra: [String: Any] = [:], payload: Data? = nil,
                     progress: (UInt64) -> Void) throws -> Status {
            try cancellation.check(); sequence += 1
            var request = extra; request["op"] = op; request["session_id"] = sessionID; request["request_id"] = sequence
            var header = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]); header.append(10)
            guard header.count <= 4096 else { throw ADBFileDeliveryFailure.invalidManifest }
            try channel.write(header, cancellation: cancellation)
            if let payload { try channel.write(payload, cancellation: cancellation) }
            while true {
                let line = try channel.readLine(cancellation: cancellation)
                guard line.count <= 8192, let response = try? JSONDecoder().decode(Response.self, from: line),
                      response.sessionID == sessionID, response.requestID == sequence else { throw ADBFileDeliveryFailure.invalidResponse }
                if response.kind == "progress", let bytes = response.bytes, bytes <= manifest.size { progress(bytes); continue }
                if response.kind == "error", let code = response.code, code.utf8.count <= 64,
                   code.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) { throw ADBFileDeliveryFailure.remote(code) }
                guard response.kind == "ack", let status = response.status, status.offset <= manifest.size,
                      isHex(status.prefixSHA256, count: 64),
                      !status.complete || (status.offset == manifest.size && status.prefixSHA256 == manifest.sha256 && !status.cancelled) else {
                    throw ADBFileDeliveryFailure.invalidResponse
                }
                return status
            }
        }
    }
}

/// Owns one exact child. Polling uses a no-progress deadline, renewed by receiver
/// verification progress; cancellation does not wait for a 10 GiB hash to finish.
final class ADBFileDeliveryProcessChannel: ADBFileDeliveryChannel {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let idleTimeout: TimeInterval
    init(executableURL: URL, arguments: [String], idleTimeout: TimeInterval = 120) throws {
        process = Process(); process.executableURL = executableURL; process.arguments = arguments
        let outgoing = Pipe(), incoming = Pipe()
        process.standardInput = outgoing; process.standardOutput = incoming; process.standardError = FileHandle.nullDevice
        input = outgoing.fileHandleForWriting; output = incoming.fileHandleForReading
        self.idleTimeout = idleTimeout
        try process.run()
        try outgoing.fileHandleForReading.close(); try incoming.fileHandleForWriting.close()
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK)
    }
    deinit { close() }
    func close() {
        try? input.close(); try? output.close()
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
    func write(_ data: Data, cancellation: ADBFileDeliveryCancellation) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd: input.fileDescriptor, events: Int16(POLLOUT), cancellation: cancellation)
                let count = Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), min(65536, bytes.count - offset))
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw ADBFileDeliveryFailure.interrupted }
                offset += count
            }
        }
    }
    func readLine(cancellation: ADBFileDeliveryCancellation) throws -> Data {
        var result = Data()
        while result.count <= 8192 {
            try wait(fd: output.fileDescriptor, events: Int16(POLLIN), cancellation: cancellation)
            var byte: UInt8 = 0
            let count = Darwin.read(output.fileDescriptor, &byte, 1)
            guard count == 1 else { throw ADBFileDeliveryFailure.interrupted }
            if byte == 10 { return result }
            result.append(byte)
        }
        throw ADBFileDeliveryFailure.invalidResponse
    }
    private func wait(fd: Int32, events: Int16, cancellation: ADBFileDeliveryCancellation) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + idleTimeout
        while true {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ADBFileDeliveryFailure.interrupted }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready > 0 { return }
            if ready < 0 && errno != EINTR { throw ADBFileDeliveryFailure.interrupted }
        }
    }
}
