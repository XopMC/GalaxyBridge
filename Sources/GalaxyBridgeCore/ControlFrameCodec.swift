import Foundation

public enum ControlFrameCodecError: Error, Equatable {
    case payloadTooLarge(Int)
}

public enum ControlFrameCodec {
    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= Int(UInt32.max) else {
            throw ControlFrameCodecError.payloadTooLarge(payload.count)
        }

        var networkLength = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &networkLength) { Data($0) }
        frame.append(payload)
        return frame
    }
}

public struct ControlFrameDecoder {
    private var buffer = Data()
    private let maxPayloadLength: Int

    public var retainedStorageByteCount: Int { buffer.count }

    public init(maxPayloadLength: Int) {
        precondition(maxPayloadLength >= 0)
        self.maxPayloadLength = maxPayloadLength
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        var consumedStorage = false
        defer {
            if consumedStorage { compactStorage() }
        }

        while buffer.count >= MemoryLayout<UInt32>.size {
            let prefix = buffer.prefix(MemoryLayout<UInt32>.size)
            let payloadLength = prefix.reduce(UInt32.zero) { partial, byte in
                (partial << 8) | UInt32(byte)
            }

            guard payloadLength <= UInt32(maxPayloadLength) else {
                throw ControlFrameCodecError.payloadTooLarge(Int(payloadLength))
            }

            let frameLength = MemoryLayout<UInt32>.size + Int(payloadLength)
            guard buffer.count >= frameLength else {
                break
            }

            let payloadStart = buffer.index(
                buffer.startIndex,
                offsetBy: MemoryLayout<UInt32>.size
            )
            let payloadEnd = buffer.index(payloadStart, offsetBy: Int(payloadLength))
            frames.append(Data(buffer[payloadStart ..< payloadEnd]))
            buffer.removeSubrange(buffer.startIndex ..< payloadEnd)
            consumedStorage = true
        }

        return frames
    }

    private mutating func compactStorage() {
        if buffer.isEmpty {
            buffer = Data()
        } else {
            buffer = buffer.withUnsafeBytes { Data($0) }
        }
    }
}
