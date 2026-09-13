import Foundation
import GalaxyBridgeProtocol

func fixtureBytes() throws -> [UInt8] {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fixtureURL = root.appendingPathComponent("protocol/fixtures/envelope_v1.hex")
    let hex = try String(contentsOf: fixtureURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard hex.count.isMultiple(of: 2) else {
        throw NSError(domain: "GalaxyBridgeProtocolSpec", code: 1)
    }

    return stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        let end = hex.index(start, offsetBy: 2)
        guard let byte = UInt8(hex[start..<end], radix: 16) else {
            fatalError("invalid hex fixture")
        }
        return byte
    }
}

do {
    let fixture = try fixtureBytes()
    let envelope = try GBEnvelope(serializedBytes: fixture)

    guard envelope.protocolMajor == 1, envelope.messageID == 42 else {
        throw NSError(domain: "GalaxyBridgeProtocolSpec", code: 2)
    }
    guard try envelope.serializedBytes() == fixture else {
        throw NSError(domain: "GalaxyBridgeProtocolSpec", code: 3)
    }

    var cameraStatus = GBCameraStatus()
    cameraStatus.requestID = "camera-request-1"
    cameraStatus.state = .awaitingUserConfirmation
    cameraStatus.reasonCode = "camera_confirmation_required"
    cameraStatus.retryable = true
    var statusEnvelope = GBEnvelope()
    statusEnvelope.protocolMajor = 1
    statusEnvelope.protocolMinor = 1
    statusEnvelope.cameraStatus = cameraStatus
    let decodedStatus = try GBEnvelope(serializedBytes: statusEnvelope.serializedData())
    guard decodedStatus.cameraStatus.requestID == "camera-request-1",
          decodedStatus.cameraStatus.state == .awaitingUserConfirmation,
          decodedStatus.cameraStatus.retryable
    else {
        throw NSError(domain: "GalaxyBridgeProtocolSpec", code: 4)
    }

    print("PASS GalaxyBridge protobuf golden fixture")
} catch {
    FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
    exit(1)
}
