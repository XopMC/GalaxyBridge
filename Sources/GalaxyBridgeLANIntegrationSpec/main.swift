import CryptoKit
import Darwin
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeProtocol

setbuf(stdout, nil)
setbuf(stderr, nil)

enum SpecFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SpecFailure.failed(message) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw SpecFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

func expectThrows<E: Error & Equatable>(
    _ expected: E,
    _ message: String,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        throw SpecFailure.failed("\(message): expected \(expected), got no error")
    } catch let error as E {
        try expectEqual(error, expected, message)
    }
}

func decodeFragmented(_ wireData: Data, pattern: [Int]) throws -> [Data] {
    var decoder = ControlFrameDecoder(maxPayloadLength: 8 * 1024 * 1024)
    var frames: [Data] = []
    var offset = 0
    var index = 0
    while offset < wireData.count {
        let length = min(pattern[index % pattern.count], wireData.count - offset)
        frames.append(contentsOf: try decoder.append(wireData.subdata(in: offset ..< offset + length)))
        offset += length
        index += 1
    }
    return frames
}

func decodeFragmentedMedia(_ wireData: Data, pattern: [Int]) throws -> [MediaPacket] {
    var decoder = MediaPacketDecoder(maxPayloadLength: 8 * 1024 * 1024)
    var packets: [MediaPacket] = []
    var offset = 0
    var index = 0
    while offset < wireData.count {
        let length = min(pattern[index % pattern.count], wireData.count - offset)
        packets.append(contentsOf: try decoder.append(wireData.subdata(in: offset ..< offset + length)))
        offset += length
        index += 1
    }
    return packets
}

do {
    let selectedAddresses = PairingAddressSelector.select(
        candidates: [
            PairingAddressCandidate(interfaceName: "utun2", address: "10.99.0.2"),
            PairingAddressCandidate(interfaceName: "en0", address: "8.8.8.8"),
            PairingAddressCandidate(interfaceName: "en1", address: "192.168.1.20"),
            PairingAddressCandidate(interfaceName: "en0", address: "10.0.0.5"),
            PairingAddressCandidate(interfaceName: "bridge100", address: "169.254.1.8"),
            PairingAddressCandidate(interfaceName: "en0", address: "fd12:3456::8"),
            PairingAddressCandidate(interfaceName: "en0", address: "fe80::4%en0"),
            PairingAddressCandidate(interfaceName: "en0", address: "10.0.0.5"),
        ],
        hostname: "galaxybridge-test.local"
    )
    try expectEqual(
        selectedAddresses,
        [
            "10.0.0.5",
            "192.168.1.20",
            "fd12:3456::8",
            "169.254.1.8",
            "fe80::4%en0",
            "galaxybridge-test.local",
        ],
        "LAN address selection must reject public/VPN addresses, deduplicate, and keep scope priority"
    )
    print("PASS Companion LAN address selection and bounded publication")

    let now = Date(timeIntervalSince1970: 1_000)
    let token = Data((0 ..< PairingQRCode.tokenLength).map(UInt8.init))
    let certificateDER = Data("GalaxyBridge local TLS certificate fixture".utf8)
    let certificatePin = TLSCertificatePinVerifier.fingerprint(certificateDER: certificateDER)
    let pairingPayload = PairingPayload(
        version: PairingQRCode.supportedVersion,
        hostID: UUID(uuidString: "12345678-1234-5678-90AB-1234567890AB")!,
        addresses: selectedAddresses,
        port: 47_920,
        token: token,
        publicKeyFingerprint: certificatePin,
        expiresAt: now.addingTimeInterval(PairingQRCode.maximumLifetime)
    )
    let pairingURL = try PairingQRCode.encode(pairingPayload)
    try expectEqual(
        try PairingQRCode.decode(pairingURL, now: now),
        pairingPayload,
        "Pairing QR must preserve all authenticated LAN endpoints at the 120-second TTL boundary"
    )
    try expectThrows(PairingQRCodeError.expired, "Pairing QR must reject an expired one-time token") {
        _ = try PairingQRCode.decode(pairingURL, now: pairingPayload.expiresAt)
    }
    print("PASS Companion LAN pairing QR round-trip and expiry boundary")

    let macKey = P256.Signing.PrivateKey()
    let androidKey = P256.Signing.PrivateKey()
    let clientNonce = Data(repeating: 0xC1, count: 32)
    let serverNonce = Data(repeating: 0x5E, count: 32)
    let displayName = "Integration Mac"

    var request = GBPairingRequest()
    request.oneTimeToken = token
    request.identityPublicKey = macKey.publicKey.x963Representation
    request.displayName = displayName
    request.clientNonce = clientNonce
    request.transcriptSignature = try macKey.signature(
        for: PairingTranscript.makeRequest(
            token: token,
            clientNonce: clientNonce,
            macPublicKey: macKey.publicKey.x963Representation,
            displayName: Data(displayName.utf8)
        )
    ).derRepresentation

    var requestEnvelope = GBEnvelope()
    requestEnvelope.protocolMajor = 1
    requestEnvelope.protocolMinor = 0
    requestEnvelope.deviceID = pairingPayload.hostID.uuidString.lowercased()
    requestEnvelope.sessionID = "pairing-integration-session"
    requestEnvelope.messageID = 1
    requestEnvelope.pairingRequest = request

    var response = GBPairingResponse()
    response.accepted = true
    response.identityPublicKey = androidKey.publicKey.x963Representation
    response.serverNonce = serverNonce
    response.tlsCertificateSha256 = certificatePin
    response.displayName = "Galaxy S24 Ultra"
    response.deviceID = "integration-device"
    response.transcriptSignature = try androidKey.signature(
        for: PairingTranscript.make(
            token: token,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            macPublicKey: macKey.publicKey.x963Representation,
            androidPublicKey: androidKey.publicKey.x963Representation
        )
    ).derRepresentation

    var responseEnvelope = GBEnvelope()
    responseEnvelope.protocolMajor = 1
    responseEnvelope.protocolMinor = 0
    responseEnvelope.deviceID = response.deviceID
    responseEnvelope.sessionID = requestEnvelope.sessionID
    responseEnvelope.messageID = 2
    responseEnvelope.pairingResponse = response

    let requestPayload = try requestEnvelope.serializedData()
    let responsePayload = try responseEnvelope.serializedData()
    let requestFrame = try ControlFrameCodec.encode(requestPayload)
    let responseFrame = try ControlFrameCodec.encode(responsePayload)
    var wireData = requestFrame
    wireData.append(responseFrame)
    let decodedFrames = try decodeFragmented(wireData, pattern: [1, 2, 7, 3, 31, 5])
    try expectEqual(decodedFrames.count, 2, "Fragmented/coalesced control stream must yield two envelopes")

    let decodedRequestEnvelope = try GBEnvelope(serializedBytes: decodedFrames[0])
    guard case let .pairingRequest(decodedRequest)? = decodedRequestEnvelope.payload else {
        throw SpecFailure.failed("First control frame did not contain a pairing request")
    }
    try expect(
        try PairingTranscript.verify(
            signatureDER: decodedRequest.transcriptSignature,
            transcript: PairingTranscript.makeRequest(
                token: decodedRequest.oneTimeToken,
                clientNonce: decodedRequest.clientNonce,
                macPublicKey: decodedRequest.identityPublicKey,
                displayName: Data(decodedRequest.displayName.utf8)
            ),
            publicKeyX963: decodedRequest.identityPublicKey
        ),
        "Pairing request signature must survive protobuf and fragmented framing"
    )

    let decodedResponseEnvelope = try GBEnvelope(serializedBytes: decodedFrames[1])
    guard case let .pairingResponse(decodedResponse)? = decodedResponseEnvelope.payload else {
        throw SpecFailure.failed("Second control frame did not contain a pairing response")
    }
    try expect(
        try PairingTranscript.verify(
            signatureDER: decodedResponse.transcriptSignature,
            transcript: PairingTranscript.make(
                token: token,
                clientNonce: clientNonce,
                serverNonce: decodedResponse.serverNonce,
                macPublicKey: macKey.publicKey.x963Representation,
                androidPublicKey: decodedResponse.identityPublicKey
            ),
            publicKeyX963: decodedResponse.identityPublicKey
        ),
        "Pairing response signature must bind both identities and nonces"
    )
    try expectEqual(
        decodedResponse.tlsCertificateSha256,
        certificatePin,
        "Pairing response must carry the pinned TLS certificate fingerprint"
    )

    let commitTranscript = PairingTranscript.makeCommit(
        token: token,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        macPublicKey: macKey.publicKey.x963Representation,
        androidPublicKey: androidKey.publicKey.x963Representation,
        hostID: requestEnvelope.deviceID,
        deviceID: responseEnvelope.deviceID,
        sessionID: requestEnvelope.sessionID
    )
    let commitSignature = try macKey.signature(for: commitTranscript).derRepresentation
    var commit = GBPairingCommit()
    commit.hostID = requestEnvelope.deviceID
    commit.deviceID = responseEnvelope.deviceID
    commit.sessionID = requestEnvelope.sessionID
    commit.transcriptSignature = commitSignature
    var commitEnvelope = GBEnvelope()
    commitEnvelope.protocolMajor = 1
    commitEnvelope.protocolMinor = 0
    commitEnvelope.deviceID = requestEnvelope.deviceID
    commitEnvelope.sessionID = requestEnvelope.sessionID
    commitEnvelope.messageID = 3
    commitEnvelope.pairingCommit = commit

    let acknowledgementTranscript = PairingTranscript.makeCommitAcknowledgement(
        commitTranscript: commitTranscript,
        commitSignature: commitSignature
    )
    var acknowledgement = GBPairingCommitAck()
    acknowledgement.committed = true
    acknowledgement.hostID = requestEnvelope.deviceID
    acknowledgement.deviceID = responseEnvelope.deviceID
    acknowledgement.sessionID = requestEnvelope.sessionID
    acknowledgement.transcriptSignature = try androidKey.signature(
        for: acknowledgementTranscript
    ).derRepresentation
    var acknowledgementEnvelope = GBEnvelope()
    acknowledgementEnvelope.protocolMajor = 1
    acknowledgementEnvelope.protocolMinor = 0
    acknowledgementEnvelope.deviceID = responseEnvelope.deviceID
    acknowledgementEnvelope.sessionID = requestEnvelope.sessionID
    acknowledgementEnvelope.messageID = 4
    acknowledgementEnvelope.pairingCommitAck = acknowledgement

    let twoPhaseFrames = try decodeFragmented(
        try ControlFrameCodec.encode(try commitEnvelope.serializedData()) +
            ControlFrameCodec.encode(try acknowledgementEnvelope.serializedData()),
        pattern: [3, 1, 17, 2, 41]
    )
    try expectEqual(twoPhaseFrames.count, 2, "Commit and acknowledgement must survive fragmented framing")
    let decodedCommitEnvelope = try GBEnvelope(serializedBytes: twoPhaseFrames[0])
    let decodedAckEnvelope = try GBEnvelope(serializedBytes: twoPhaseFrames[1])
    try expectEqual(decodedCommitEnvelope.pairingCommit, commit, "Pairing commit protobuf must round-trip")
    try expectEqual(
        decodedAckEnvelope.pairingCommitAck,
        acknowledgement,
        "Pairing commit acknowledgement protobuf must round-trip"
    )
    print("PASS Companion two-phase pairing protobuf exchange over fragmented control framing")

    var boundedDecoder = ControlFrameDecoder(maxPayloadLength: 16)
    try expectThrows(
        ControlFrameCodecError.payloadTooLarge(17),
        "Control decoder must reject an oversized LAN payload before buffering it"
    ) {
        _ = try boundedDecoder.append(Data([0, 0, 0, 17]))
    }
    print("PASS Companion control framing rejects oversized payloads")

    let videoConfiguration = MediaPacket(
        flags: [.configuration],
        epoch: 7,
        presentationTimeUs: 10,
        payload: Data([0x01, 0x64, 0x00, 0x28])
    )
    let videoFrame = MediaPacket(
        flags: [.keyFrame],
        epoch: 7,
        presentationTimeUs: 20,
        payload: Data([0x00, 0x00, 0x00, 0x01, 0x26])
    )
    var mediaWireData = try MediaPacketCodec.encode(videoConfiguration)
    mediaWireData.append(try MediaPacketCodec.encode(videoFrame))
    try expectEqual(
        try decodeFragmentedMedia(mediaWireData, pattern: [2, 1, 19, 3, 64]),
        [videoConfiguration, videoFrame],
        "Companion media channel must decode coalesced packets after arbitrary TCP fragmentation"
    )
    print("PASS Companion media framing handles fragmented and coalesced packets")

    try expect(
        TLSCertificatePinVerifier.matches(
            certificateDER: certificateDER,
            expectedSHA256: certificatePin
        ),
        "TLS certificate pin must accept the exact paired certificate"
    )
    try expect(
        !TLSCertificatePinVerifier.matches(
            certificateDER: certificateDER + Data([0]),
            expectedSHA256: certificatePin
        ),
        "TLS certificate pin must reject a different certificate"
    )
    try expect(
        !TLSCertificatePinVerifier.matches(
            certificateDER: certificateDER,
            expectedSHA256: certificatePin.dropLast()
        ),
        "TLS certificate pin must reject a malformed fingerprint"
    )
    print("PASS Companion TLS certificate pin acceptance and rejection")

    try expectEqual(
        ScreenStreamPlaceholderResolver.resolve(
            deviceReady: true,
            hasFrame: true,
            screenCapabilityUnavailableReason: "media_projection_consent_required"
        ),
        .mediaProjectionConsentRequired,
        "MediaProjection revocation must replace even a stale frame with a clear placeholder"
    )
    try expectEqual(
        ScreenStreamPlaceholderResolver.resolve(
            deviceReady: true,
            hasFrame: false,
            screenCapabilityUnavailableReason: nil
        ),
        .waitingForFirstFrame,
        "Connected companion without a frame must show a waiting placeholder"
    )
    try expectEqual(
        ScreenStreamPlaceholderResolver.resolve(
            deviceReady: true,
            hasFrame: true,
            screenCapabilityUnavailableReason: nil
        ),
        nil,
        "Available screen capture with a decoded frame must not show a placeholder"
    )
    try expectEqual(
        ScreenStreamPlaceholderResolver.resolve(
            deviceReady: true,
            hasFrame: true,
            screenCapabilityUnavailableReason: nil,
            protectedContentSuspected: true
        ),
        .protectedContent,
        "sustained black capture must be fully covered by a protected-content placeholder"
    )
    print("PASS Companion viewer placeholder policy covers consent, first-frame, and protected states")
} catch {
    fputs("FAIL GalaxyBridgeLANIntegrationSpec: \(error)\n", stderr)
    exit(1)
}
