import Foundation

/// Reads one control frame at a time until the authenticated readiness message
/// changes the protocol. A producer header may share that same TCP read.
public struct RawChannelUpgradeDecoder: Sendable {
    public enum Failure: Error { case capacity, length, alreadyUpgraded }
    private var buffer = Data()
    private var upgraded = false
    public init() {}
    public mutating func append(_ bytes: Data) throws {
        guard !upgraded else { throw Failure.alreadyUpgraded }
        guard bytes.count <= 256 * 1024, buffer.count <= 320 * 1024 - bytes.count else { throw Failure.capacity }
        buffer.append(bytes)
    }
    public mutating func nextFrame() throws -> Data? {
        guard !upgraded else { throw Failure.alreadyUpgraded }
        guard buffer.count >= 4 else { return nil }
        let size = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= 64 * 1024 else { throw Failure.length }
        guard buffer.count >= 4 + Int(size) else { return nil }
        let frame = buffer.subdata(in: 4..<4 + Int(size))
        buffer = Data(buffer.dropFirst(4 + Int(size)))
        return frame
    }
    public mutating func takeRawRemainder() -> Data {
        upgraded = true
        let result = buffer; buffer = Data(); return result
    }
}
