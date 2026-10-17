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

    var notificationAction = GBNotificationAction()
    notificationAction.notificationID = "synthetic"
    notificationAction.actionID = "0"
    notificationAction.replyText = "Galaxy Bridge QA — ответ42"
    let legacyAction = try GBNotificationAction(serializedBytes: notificationAction.serializedData())
    precondition(legacyAction.requestID.isEmpty)
    notificationAction.requestID = "69830b65-6352-4b3a-8a21-70bcda45787e"
    let decodedAction = try GBNotificationAction(serializedBytes: notificationAction.serializedData())
    precondition(decodedAction == notificationAction)
    var actionResult = GBNotificationActionResult()
    actionResult.requestID = notificationAction.requestID
    actionResult.notificationID = notificationAction.notificationID
    actionResult.actionID = notificationAction.actionID
    actionResult.accepted = false
    actionResult.errorCode = "pending_intent_canceled"
    var resultEnvelope = GBEnvelope()
    resultEnvelope.protocolMajor = 1
    resultEnvelope.notificationActionResult = actionResult
    let decodedActionResult = try GBEnvelope(serializedBytes: resultEnvelope.serializedData())
    precondition(decodedActionResult.notificationActionResult == actionResult)
    precondition(GBCapability.notificationActionResults.rawValue == 13)

    var retirement = GBCaptureRetirementQuery()
    retirement.kind = .displayPowerController; retirement.pid = 42; retirement.processStartTicks = 123456
    var retirementRequest = GBShellBridgeRequest()
    retirementRequest.operation = .verifyRetirement
    retirementRequest.retirement = retirement
    let decodedRetirement = try GBShellBridgeRequest(serializedBytes: retirementRequest.serializedData())
    precondition(decodedRetirement.hasRetirement && decodedRetirement.retirement == retirement)
    var support = GBShellBridgeRequest()
    support.operation = .verifyRetirement; support.retirement = GBCaptureRetirementQuery()
    let decodedSupport = try GBShellBridgeRequest(serializedBytes: support.serializedData())
    precondition(decodedSupport.hasRetirement,
        "empty support query must preserve explicit message presence")
    retirement.ownedResourceID = "69830b65-6352-4b3a-8a21-70bcda45787e"
    retirement.resourceSha256 = Data(repeating: 0x11, count: 32)
    retirementRequest.operation = .releaseRetiredResource; retirementRequest.retirement = retirement
    let decodedRelease = try GBShellBridgeRequest(serializedBytes: retirementRequest.serializedData())
    precondition(decodedRelease == retirementRequest)
    var proof = GBCaptureRetirementProof()
    proof.kind = .displayPowerController; proof.pid = 42; proof.processStartTicks = 123456
    proof.supported = true; proof.absent = true
    var panel = GBPhysicalPanelPowerState(); panel.physicalID = "18446744073709551615"; panel.on = false
    proof.panels = [panel]
    var retirementResult = GBShellBridgeResult(); retirementResult.retirementProof = proof
    let decodedProof = try GBShellBridgeResult(serializedBytes: retirementResult.serializedData())
    precondition(decodedProof.hasRetirementProof && decodedProof.retirementProof == proof)
    var runtimeIdentity = GBShellBridgeResult()
    runtimeIdentity.runtimeSha256 = Data(repeating: 0x11, count: 32)
    let identityWire = [UInt8(0x52), 0x20] + Array(repeating: UInt8(0x11), count: 32)
    let actualIdentityWire: [UInt8] = try runtimeIdentity.serializedBytes()
    precondition(actualIdentityWire == identityWire)
    let decodedIdentity = try GBShellBridgeResult(serializedBytes: identityWire)
    precondition(decodedIdentity.runtimeSha256 == runtimeIdentity.runtimeSha256)
    precondition(GBCapability.shellRuntimeIdentity.rawValue == 20)
    precondition(GBCapability.compositeDisplayState.rawValue == 19)
    var typedDisplayStop = GBShellBridgeRequest()
    typedDisplayStop.operation = .stop; typedDisplayStop.displayStateStop = true
    let typedStopWire: [UInt8] = try typedDisplayStop.serializedBytes()
    precondition(typedStopWire == [0x20, 0x04, 0x48, 0x01], "typed STOP is append-only field9 with no media payload")
    let decodedTypedStop = try GBShellBridgeRequest(serializedBytes: typedStopWire)
    precondition(decodedTypedStop == typedDisplayStop)
    precondition(GBShellBridgeRequest.Operation.startDisplayState.rawValue == 8)
    var displayCommand = GBDisplayStateCommand()
    displayCommand.action = .apply; displayCommand.interactive = true; displayCommand.panelPolicy = .hide; displayCommand.revision = 17
    var displayRequest = GBShellBridgeRequest()
    displayRequest.operation = .startDisplayState; displayRequest.displayState = displayCommand
    let decodedDisplay = try GBShellBridgeRequest(serializedBytes: displayRequest.serializedData())
    precondition(decodedDisplay == displayRequest && decodedDisplay.hasDisplayState && !decodedDisplay.hasOptions)
    displayRequest.displayState = GBDisplayStateCommand()
    let decodedDisplaySnapshot = try GBShellBridgeRequest(serializedBytes: displayRequest.serializedData())
    precondition(decodedDisplaySnapshot.hasDisplayState && decodedDisplaySnapshot.displayState.action == .snapshot,
        "read-only snapshot must preserve explicit empty typed message presence")
    var displayProof = GBCaptureRetirementProof()
    displayProof.kind = .displayStateController; displayProof.pid = 42; displayProof.processStartTicks = 456
    displayProof.supported = true; displayProof.absent = true
    displayProof.displayStateSnapshot = Data("synthetic full snapshot".utf8)
    displayProof.displayStateTerminalAcknowledgement = Data("synthetic typed terminal".utf8)
    var displayResult = GBShellBridgeResult(); displayResult.retirementProof = displayProof
    let decodedDisplayProof = try GBShellBridgeResult(serializedBytes: displayResult.serializedData())
    precondition(decodedDisplayProof.retirementProof == displayProof && decodedDisplayProof.retirementProof.panels.isEmpty)
    var displayAcknowledgement = GBShellBridgeResult(); displayAcknowledgement.displayStateAcknowledgement = Data([1, 2, 3])
    let actualDisplayWire: [UInt8] = try displayAcknowledgement.serializedBytes()
    precondition(actualDisplayWire == [0x5a, 0x03, 0x01, 0x02, 0x03], "v2 ACK must use the new append-only field 11")

    print("PASS GalaxyBridge protobuf golden fixture and notification request/result compatibility")
} catch {
    FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
    exit(1)
}
