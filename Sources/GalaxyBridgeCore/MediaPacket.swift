import Foundation

public struct MediaPacketFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let configuration = Self(rawValue: 1 << 0)
    public static let keyFrame = Self(rawValue: 1 << 1)
}

public struct MediaPacket: Equatable, Sendable {
    public let flags: MediaPacketFlags
    public let epoch: UInt32
    public let presentationTimeUs: UInt64
    public let payload: Data

    public init(
        flags: MediaPacketFlags,
        epoch: UInt32,
        presentationTimeUs: UInt64,
        payload: Data
    ) {
        self.flags = flags
        self.epoch = epoch
        self.presentationTimeUs = presentationTimeUs
        self.payload = payload
    }
}

public enum MediaPacketCodecError: Error, Equatable {
    case payloadTooLarge(Int)
}

public enum MediaPacketCodec {
    public static let headerLength = 17

    public static func encode(_ packet: MediaPacket) throws -> Data {
        guard packet.payload.count <= Int(UInt32.max) else {
            throw MediaPacketCodecError.payloadTooLarge(packet.payload.count)
        }

        var encoded = Data([packet.flags.rawValue])
        encoded.appendNetworkOrder(packet.epoch)
        encoded.appendNetworkOrder(packet.presentationTimeUs)
        encoded.appendNetworkOrder(UInt32(packet.payload.count))
        encoded.append(packet.payload)
        return encoded
    }
}

public struct MediaPacketDecoder {
    private var buffer = Data()
    private let maxPayloadLength: Int

    /// Bytes still retained by the incremental decoder after compaction.
    public var retainedStorageByteCount: Int { buffer.count }

    public init(maxPayloadLength: Int) {
        precondition(maxPayloadLength >= 0)
        self.maxPayloadLength = maxPayloadLength
    }

    public mutating func append<Bytes: DataProtocol>(_ data: Bytes) throws -> [MediaPacket] {
        buffer.append(contentsOf: data)
        var packets: [MediaPacket] = []
        var consumedStorage = false
        defer {
            if consumedStorage { compactStorage() }
        }

        while buffer.count >= MediaPacketCodec.headerLength {
            let header = Array(buffer.prefix(MediaPacketCodec.headerLength))
            let payloadLength = Int(Self.readUInt32(header, offset: 13))
            guard payloadLength <= maxPayloadLength else {
                throw MediaPacketCodecError.payloadTooLarge(payloadLength)
            }

            let packetLength = MediaPacketCodec.headerLength + payloadLength
            guard buffer.count >= packetLength else {
                break
            }

            packets.append(
                MediaPacket(
                    flags: MediaPacketFlags(rawValue: header[0]),
                    epoch: Self.readUInt32(header, offset: 1),
                    presentationTimeUs: Self.readUInt64(header, offset: 5),
                    payload: Data(
                        buffer[
                            buffer.index(buffer.startIndex, offsetBy: MediaPacketCodec.headerLength)
                                ..< buffer.index(buffer.startIndex, offsetBy: packetLength)
                        ]
                    )
                )
            )
            let packetEnd = buffer.index(buffer.startIndex, offsetBy: packetLength)
            buffer.removeSubrange(buffer.startIndex ..< packetEnd)
            consumedStorage = true
        }

        return packets
    }

    private mutating func compactStorage() {
        if buffer.isEmpty {
            buffer = Data()
        } else {
            buffer = buffer.withUnsafeBytes { Data($0) }
        }
    }

    private static func readUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        bytes[offset ..< offset + MemoryLayout<UInt32>.size].reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func readUInt64(_ bytes: [UInt8], offset: Int) -> UInt64 {
        bytes[offset ..< offset + MemoryLayout<UInt64>.size].reduce(UInt64.zero) {
            ($0 << 8) | UInt64($1)
        }
    }
}

private extension Data {
    mutating func appendNetworkOrder<T: FixedWidthInteger>(_ value: T) {
        var networkValue = value.bigEndian
        Swift.withUnsafeBytes(of: &networkValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
