import CryptoKit
import Foundation

/// Messages written by the pinned scrcpy 4.1 server on the control socket.
///
/// This wire format is deliberately version-specific. It mirrors
/// `app/src/device_msg.c` from scrcpy v4.1 and must be updated atomically with
/// the pinned server artifact.
public enum ScrcpyDeviceMessage: Equatable, Sendable {
    case clipboard(Data)
    case clipboardAcknowledgement(sequence: UInt64)
    case uhidOutput(id: UInt16, payload: Data)
}

public struct ScrcpyClipboardUpdate: Equatable, Sendable {
    public let changeID: String
    public let kind: ScrcpyClipboardContentKind
    public let content: Data

    public init(changeID: String, kind: ScrcpyClipboardContentKind = .text, content: Data) {
        self.changeID = changeID
        self.kind = kind
        self.content = content
    }
}

public enum ScrcpyClipboardContentKind: UInt8, Equatable, Sendable {
    case text = 1
    case png = 3
}

public enum ScrcpyClipboardAgentError: Error, Equatable {
    case invalidPreamble
    case unknownKind(UInt8)
    case invalidLength(Int)
    case invalidOrigin
}

public struct ScrcpyClipboardAgentMessage: Equatable, Sendable {
    public let kind: ScrcpyClipboardContentKind
    public let content: Data
    public let timestamp: UInt64?
    public let originChangeID: String?

    public init(kind: ScrcpyClipboardContentKind, content: Data, timestamp: UInt64? = nil, originChangeID: String? = nil) {
        self.kind = kind
        self.content = content
        self.timestamp = timestamp
        self.originChangeID = originChangeID
    }

    /// Commands on the already-owned local socket use the same bounded GBC2
    /// frame, without a second stream preamble. Only text writes are supported.
    public static func textCommand(_ text: String, changeID: String) -> Data? {
        let payload = Data(text.utf8), origin = Data(changeID.utf8)
        guard !payload.isEmpty, payload.count <= ScrcpyDeviceMessageDecoder.maximumClipboardLength,
              !origin.isEmpty, origin.count <= 256 else { return nil }
        var result = Data([ScrcpyClipboardContentKind.text.rawValue])
        result.append(Data(repeating: 0, count: 8))
        result.append(contentsOf: [UInt8(origin.count >> 8), UInt8(truncatingIfNeeded: origin.count)])
        for shift in stride(from: 24, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: payload.count >> shift)) }
        result.append(origin); result.append(payload)
        return result
    }
}

public struct ScrcpyClipboardAgentDecoder: Sendable {
    public static let maximumPayloadLength = 4 * 1024 * 1024
    private var buffer = Data()
    private var version: UInt8?

    public init() {}

    public mutating func append<S: DataProtocol>(_ bytes: S) throws -> [ScrcpyClipboardAgentMessage] {
        buffer.append(contentsOf: bytes)
        if version == nil {
            guard buffer.count >= 4 else { return [] }
            let prefix = Data(buffer.prefix(4))
            guard prefix == Data("GBC1".utf8) || prefix == Data("GBC2".utf8) else {
                throw ScrcpyClipboardAgentError.invalidPreamble
            }
            version = prefix.last
            buffer.removeFirst(4)
        }
        var messages: [ScrcpyClipboardAgentMessage] = []
        let headerLength = version == 0x32 ? 15 : 5
        while buffer.count >= headerLength {
            guard let kind = ScrcpyClipboardContentKind(rawValue: buffer[buffer.startIndex]) else {
                throw ScrcpyClipboardAgentError.unknownKind(buffer[buffer.startIndex])
            }
            let originLength = headerLength == 15 ? Int(readWord(at: 9, count: 2)) : 0
            guard originLength <= 256 else { throw ScrcpyClipboardAgentError.invalidOrigin }
            let length = Int(readWord(at: headerLength == 15 ? 11 : 1, count: 4))
            guard length > 0, length <= Self.maximumPayloadLength else {
                throw ScrcpyClipboardAgentError.invalidLength(length)
            }
            guard buffer.count >= headerLength + originLength + length else { break }
            let originStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
            let start = buffer.index(originStart, offsetBy: originLength)
            let end = buffer.index(start, offsetBy: length)
            let origin: String?
            if originLength > 0 {
                guard let decoded = String(data: buffer[originStart..<start], encoding: .utf8) else {
                    throw ScrcpyClipboardAgentError.invalidOrigin
                }
                origin = decoded
            } else { origin = nil }
            messages.append(.init(kind: kind, content: Data(buffer[start ..< end]),
                timestamp: headerLength == 15 ? readWord(at: 1, count: 8) : nil,
                originChangeID: origin))
            buffer.removeFirst(headerLength + originLength + length)
        }
        return messages
    }

    private func readWord(at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in buffer.dropFirst(offset).prefix(count) { value = (value << 8) | UInt64(byte) }
        return value
    }
}

public enum ScrcpyClipboardIdentity {
    public static func changeID(
        serial: String,
        sessionID: String,
        sequence: UInt64,
        content: Data
    ) -> String {
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return "scrcpy:\(serial):\(sessionID):\(sequence):\(digest)"
    }
}

public enum ScrcpyDeviceMessageError: Error, Equatable, LocalizedError {
    case unknownType(UInt8)
    case invalidClipboardLength(Int)

    public var errorDescription: String? {
        switch self {
        case let .unknownType(type):
            "Unknown scrcpy 4.1 device-message type \(type)"
        case let .invalidClipboardLength(length):
            "Invalid scrcpy 4.1 clipboard payload length \(length)"
        }
    }
}

public struct ScrcpyDeviceMessageDecoder: Sendable {
    /// scrcpy v4.1 `DEVICE_MSG_MAX_SIZE`.
    public static let maximumMessageLength = 1 << 18
    public static let maximumClipboardLength = maximumMessageLength - 5

    private var buffer = Data()

    /// Exact unread bytes retained by the incremental decoder. Exposed so the
    /// sustained-stream regression can prove that consumed control traffic
    /// does not pin the complete scrcpy session in memory.
    public var retainedStorageByteCount: Int { buffer.count }

    public init() {}

    public mutating func append<S: DataProtocol>(_ bytes: S) throws -> [ScrcpyDeviceMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [ScrcpyDeviceMessage] = []
        var consumedStorage = false
        defer {
            if consumedStorage { compactStorage() }
        }

        while let type = buffer.first {
            switch type {
            case 0:
                guard buffer.count >= 5 else { return messages }
                let length = Int(readUInt32(at: 1))
                guard length <= Self.maximumClipboardLength else {
                    throw ScrcpyDeviceMessageError.invalidClipboardLength(length)
                }
                guard buffer.count >= 5 + length else { return messages }
                messages.append(.clipboard(payload(at: 5, length: length)))
                buffer.removeFirst(5 + length)
                consumedStorage = true

            case 1:
                guard buffer.count >= 9 else { return messages }
                messages.append(.clipboardAcknowledgement(sequence: readUInt64(at: 1)))
                buffer.removeFirst(9)
                consumedStorage = true

            case 2:
                guard buffer.count >= 5 else { return messages }
                let id = readUInt16(at: 1)
                let length = Int(readUInt16(at: 3))
                guard buffer.count >= 5 + length else { return messages }
                messages.append(.uhidOutput(id: id, payload: payload(at: 5, length: length)))
                buffer.removeFirst(5 + length)
                consumedStorage = true

            default:
                throw ScrcpyDeviceMessageError.unknownType(type)
            }
        }

        return messages
    }

    private mutating func compactStorage() {
        if buffer.isEmpty {
            buffer = Data()
        } else {
            buffer = buffer.withUnsafeBytes { Data($0) }
        }
    }

    private func payload(at offset: Int, length: Int) -> Data {
        let start = buffer.index(buffer.startIndex, offsetBy: offset)
        let end = buffer.index(start, offsetBy: length)
        return Data(buffer[start ..< end])
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        integer(at: offset, byteCount: 2)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        integer(at: offset, byteCount: 4)
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        integer(at: offset, byteCount: 8)
    }

    private func integer<T: FixedWidthInteger>(at offset: Int, byteCount: Int) -> T {
        let start = buffer.index(buffer.startIndex, offsetBy: offset)
        let end = buffer.index(start, offsetBy: byteCount)
        return buffer[start ..< end].reduce(0) { ($0 << 8) | T($1) }
    }
}

/// Serial receive-side state for the full-duplex scrcpy control channel.
/// `NWConnection` owns scheduling; this object owns framing and guarantees that
/// a corrupt stream produces one terminal failure and no later callbacks.
public final class ScrcpyControlReceivePipeline: @unchecked Sendable {
    private var decoder = ScrcpyDeviceMessageDecoder()
    private var terminated = false
    private let messageHandler: @Sendable (ScrcpyDeviceMessage) -> Void
    private let failureHandler: @Sendable (Error) -> Void

    public init(
        messageHandler: @escaping @Sendable (ScrcpyDeviceMessage) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.messageHandler = messageHandler
        self.failureHandler = failureHandler
    }

    @discardableResult
    public func consume<S: DataProtocol>(_ bytes: S) -> Bool {
        guard !terminated else { return false }
        guard !bytes.isEmpty else { return true }
        do {
            for message in try decoder.append(bytes) {
                messageHandler(message)
            }
        } catch {
            terminate(error)
        }
        return !terminated
    }

    public func terminate(_ error: Error) {
        guard !terminated else { return }
        terminated = true
        failureHandler(error)
    }

    public func cancel() {
        terminated = true
    }
}
