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
        var wire = Data("GBC2".utf8)
        wire.append(frame(timestamp: 100, origin: "hub:synthetic", payload: "A"))
        wire.append(frame(timestamp: 101, origin: "", payload: "A"))
        var messages: [ScrcpyClipboardAgentMessage] = []
        for byte in wire { messages += try decoder.append(Data([byte])) }
        precondition(messages.count == 2, "Two real same-byte copies must survive incremental decoding")
        precondition(messages[0].originChangeID == "hub:synthetic")
        precondition(messages[1].originChangeID == nil)
        precondition(messages[0].timestamp == 100 && messages[1].timestamp == 101)
        precondition(messages[0].content == messages[1].content)
        var legacy = ScrcpyClipboardAgentDecoder()
        let old = try legacy.append(Data("GBC1".utf8) + Data([1, 0, 0, 0, 1, 65]))
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
        print("PASS GBC2 fragmented framing, same-byte occurrences and exact injection origin")
    }
}
