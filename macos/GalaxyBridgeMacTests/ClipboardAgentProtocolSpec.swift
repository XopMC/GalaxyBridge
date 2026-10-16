import Foundation

@main
enum ClipboardAgentProtocolSpec {
    static func main() throws {
        func frame(timestamp: UInt64, origin: String, payload: String) -> Data {
            var result = Data([1])
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: timestamp >> shift)) }
            let identity = Data(origin.utf8), content = Data(payload.utf8)
            result.append(contentsOf: [UInt8(identity.count >> 8), UInt8(truncatingIfNeeded: identity.count)])
            for shift in stride(from: 24, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: content.count >> shift)) }
            result.append(identity); result.append(content)
            return result
        }
        var decoder = ScrcpyClipboardAgentDecoder()
        precondition(decoder.supportsOccurrences == nil)
        var wire = Data("GBC2".utf8)
        wire.append(frame(timestamp: 100, origin: "hub:synthetic", payload: "A"))
        wire.append(frame(timestamp: 101, origin: "", payload: "A"))
        var messages: [ScrcpyClipboardAgentMessage] = []
        for byte in wire { messages += try decoder.append(Data([byte])) }
        precondition(decoder.supportsOccurrences == true)
        precondition(messages.count == 2, "Two real same-byte copies must survive incremental decoding")
        precondition(messages[0].originChangeID == "hub:synthetic")
        precondition(messages[1].originChangeID == nil)
        precondition(messages[0].timestamp == 100 && messages[1].timestamp == 101)
        precondition(messages[0].content == messages[1].content)
        var legacy = ScrcpyClipboardAgentDecoder()
        let old = try legacy.append(Data("GBC1".utf8) + Data([1, 0, 0, 0, 1, 65]))
        precondition(legacy.supportsOccurrences == false)
        precondition(old.count == 1 && old[0].timestamp == nil && old[0].content == Data("A".utf8))
        let command = ScrcpyClipboardAgentMessage.textCommand("Привет", changeID: "hub:write")!
        var commands = ScrcpyClipboardAgentDecoder()
        let decodedCommand = try commands.append(Data("GBC2".utf8) + command)
        precondition(decodedCommand[0].content == Data("Привет".utf8) && decodedCommand[0].originChangeID == "hub:write")
        precondition(ScrcpyClipboardAgentMessage.textCommand("A", changeID: String(repeating: "я", count: 129)) == nil)
        var invalid = ScrcpyClipboardAgentDecoder()
        var malformed = Data("GBC2".utf8) + frame(timestamp: 1, origin: "", payload: "A")
        malformed[13] = 1; malformed[14] = 1 // 257 origin bytes exceeds protocol bound.
        do { _ = try invalid.append(malformed); preconditionFailure("Oversize origin accepted") }
        catch ScrcpyClipboardAgentError.invalidOrigin {}
        var current = ScrcpyClipboardAgentDecoder()
        let unavailable = Data(repeating: 0, count: 15)
        var v3: [ScrcpyClipboardAgentMessage] = []
        for byte in Data("GBC3".utf8) + unavailable + frame(timestamp: 102, origin: "", payload: "A") {
            v3 += try current.append(Data([byte]))
        }
        precondition(current.supportsOccurrences == true && v3.count == 2)
        precondition(!v3[0].isAvailable && v3[0].content.isEmpty && v3[1].isAvailable)
        for version in ["GBC1", "GBC2"] {
            var oldDecoder = ScrcpyClipboardAgentDecoder()
            do { _ = try oldDecoder.append(Data(version.utf8) + unavailable); preconditionFailure("Legacy zero-kind accepted") }
            catch ScrcpyClipboardAgentError.unknownKind(0) {}
        }
        for offset in [1, 9, 11] {
            var bad = unavailable; bad[offset] = 1
            var malformedStatus = ScrcpyClipboardAgentDecoder()
            do { _ = try malformedStatus.append(Data("GBC3".utf8) + bad); preconditionFailure("Unavailable frame carried nonzero metadata") }
            catch ScrcpyClipboardAgentError.invalidLength(0) {}
        }
        print("PASS GBC1/2 compatibility and fragmented GBC3 occurrences/unavailable status, strict status bounds, same-byte copies and exact injection origin")
    }
}
