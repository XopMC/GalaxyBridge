import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore

enum SpecFailure: Error, CustomStringConvertible {
    case mismatch(name: String, actual: String, expected: String)

    var description: String {
        switch self {
        case let .mismatch(name, actual, expected):
            return "\(name): expected \(expected), got \(actual)"
        }
    }
}

final class ScrcpyReceiveProbe: @unchecked Sendable {
    var messages: [ScrcpyDeviceMessage] = []
    var failures: [String] = []
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) throws {
    guard actual == expected else {
        throw SpecFailure.mismatch(
            name: name,
            actual: String(describing: actual),
            expected: String(describing: expected)
        )
    }
}

func require<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else {
        throw SpecFailure.mismatch(name: name, actual: "nil", expected: "non-nil")
    }
    return value
}

func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    try expectEqual(condition(), true, name)
}

func expectThrows<E: Error & Equatable>(
    _ expected: E,
    _ name: String,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        throw SpecFailure.mismatch(
            name: name,
            actual: "no error",
            expected: String(describing: expected)
        )
    } catch let error as E {
        try expectEqual(error, expected, name)
    }
}

do {
    let encoded = try ControlFrameCodec.encode(Data([0xCA, 0xFE]))
    try expectEqual(
        Array(encoded),
        [0x00, 0x00, 0x00, 0x02, 0xCA, 0xFE],
        "control frame uses a big-endian length prefix"
    )
    print("PASS ControlFrameCodec encodes a big-endian length prefix")

    var decoder = ControlFrameDecoder(maxPayloadLength: 1_024)
    try expectEqual(
        try decoder.append(Data([0x00, 0x00])),
        [],
        "control decoder waits for a complete prefix"
    )
    try expectEqual(
        try decoder.append(Data([0x00, 0x02, 0xAA])),
        [],
        "control decoder waits for a complete payload"
    )
    try expectEqual(
        try decoder.append(Data([0xBB])),
        [Data([0xAA, 0xBB])],
        "control decoder reassembles fragmented frames"
    )
    let sustainedControlFrame = try ControlFrameCodec.encode(Data(repeating: 0xC3, count: 768))
    for _ in 0 ..< 4_096 {
        _ = try decoder.append(sustainedControlFrame)
    }
    try expectEqual(
        decoder.retainedStorageByteCount,
        0,
        "fully consumed control frames must release their backing storage instead of retaining the complete session"
    )
    print("PASS ControlFrameDecoder reassembles fragmented frames")

    let mediaPacket = MediaPacket(
        flags: [.configuration, .keyFrame],
        epoch: 0x0102_0304,
        presentationTimeUs: 0x0102_0304_0506_0708,
        payload: Data([0xAA, 0xBB])
    )
    let encodedMedia = try MediaPacketCodec.encode(mediaPacket)
    try expectEqual(
        Array(encodedMedia),
        [
            0x03,
            0x01, 0x02, 0x03, 0x04,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x00, 0x00, 0x00, 0x02,
            0xAA, 0xBB,
        ],
        "media packet uses the documented network-byte-order header"
    )
    print("PASS MediaPacketCodec encodes the documented header")

    var mediaDecoder = MediaPacketDecoder(maxPayloadLength: 128 * 1_024)
    try expectEqual(
        try mediaDecoder.append(encodedMedia.prefix(10)),
        [],
        "media decoder waits for a complete packet"
    )
    try expectEqual(
        try mediaDecoder.append(encodedMedia.dropFirst(10)),
        [mediaPacket],
        "media decoder reassembles a fragmented packet"
    )
    let sustainedMediaPacket = try MediaPacketCodec.encode(
        MediaPacket(
            flags: [.keyFrame],
            epoch: 7,
            presentationTimeUs: 42,
            payload: Data(repeating: 0xA5, count: 64 * 1_024)
        )
    )
    for _ in 0 ..< 512 {
        _ = try mediaDecoder.append(sustainedMediaPacket)
    }
    try expectEqual(
        mediaDecoder.retainedStorageByteCount,
        0,
        "fully consumed media bytes must release their backing storage instead of growing for the life of the stream"
    )
    print("PASS MediaPacketDecoder reassembles fragmented packets")

    var stateMachine = DeviceSessionStateMachine(initialState: .discovered)
    try stateMachine.transition(to: .pairing)
    try stateMachine.transition(to: .connecting)
    try stateMachine.transition(to: .connected)
    try stateMachine.transition(to: .degraded)
    try stateMachine.transition(to: .reconnecting)
    try stateMachine.transition(to: .connected)
    try expectEqual(
        stateMachine.state,
        .connected,
        "session state machine follows the documented recovery path"
    )
    print("PASS DeviceSessionStateMachine follows the recovery path")

    var reconnectBackoff = ReconnectBackoff()
    var observedDelays: [Duration] = []
    for _ in 0 ..< 7 {
        observedDelays.append(reconnectBackoff.nextDelay())
    }
    try expectEqual(
        observedDelays,
        [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30), .seconds(30), .seconds(30)],
        "reconnect backoff follows the documented schedule and clamps"
    )
    print("PASS ReconnectBackoff follows the documented schedule")

    let preferredTransport = TransportSelector.preferred(
        from: [.companionLAN, .wirelessADB, .usbADB]
    )
    try expectEqual(
        preferredTransport,
        .usbADB,
        "transport selector prefers USB ADB over wireless ADB and LAN"
    )
    print("PASS TransportSelector prefers USB ADB")

    var topologyRefresh = ADBTopologyRefreshState()
    try expectEqual(
        topologyRefresh.begin(),
        true,
        "the first ADB topology probe starts"
    )
    try expectEqual(
        topologyRefresh.begin(),
        false,
        "a periodic topology probe must not overlap an in-flight adb devices command"
    )
    topologyRefresh.finish()
    try expectEqual(
        topologyRefresh.begin(),
        true,
        "the next topology probe starts after the prior command finishes"
    )
    topologyRefresh.finish()
    try expectEqual(
        ADBTopologyRefreshState.shouldPublish(
            previous: ["serial-a": true],
            current: ["serial-a": true]
        ),
        false,
        "an unchanged ADB snapshot must not churn the merged device model"
    )
    try expectEqual(
        ADBTopologyRefreshState.shouldPublish(
            previous: ["serial-a": true],
            current: [:]
        ),
        true,
        "losing the ADB device must immediately publish topology fallback"
    )
    print("PASS ADB topology refresh is serialized and publishes physical disconnects")

    try expectEqual(
        TransportSelector.presented(
            from: [
                TransportSnapshot(kind: .usbADB, isConnected: false, capabilities: []),
                TransportSnapshot(kind: .companionLAN, isConnected: true, capabilities: []),
            ]
        ),
        [.companionLAN],
        "the UI must not label a stale ADB discovery as connected after falling back to LAN"
    )
    try expectEqual(
        TransportSelector.presented(
            from: [
                TransportSnapshot(kind: .usbADB, isConnected: true, capabilities: []),
                TransportSnapshot(kind: .companionLAN, isConnected: true, capabilities: []),
            ]
        ),
        [.usbADB, .companionLAN],
        "the UI presents every currently connected transport in priority order"
    )
    print("PASS transport presentation excludes disconnected routes")
    try expectEqual(
        TransportSelector.connectionLabelKeys(for: [.wirelessADB, .companionLAN]),
        ["COMPANION_LAN"],
        "two wireless services on one phone must appear as one Wi-Fi connection"
    )
    try expectEqual(
        TransportSelector.connectionLabelKeys(for: [.usbADB, .wirelessADB, .companionLAN]),
        ["USB_ADB", "COMPANION_LAN"],
        "a real cable and Wi-Fi remain distinguishable"
    )

    try expectEqual(
        CompanionRoutedFallback.port,
        46_737,
        "the authenticated companion server exposes one stable routed-LAN fallback port"
    )
    try expectEqual(
        ADBWiFiIPv4AddressParser.parse(
            "45: wlan0    inet 192.168.42.112/24 brd 192.168.42.255 scope global wlan0"
        ),
        "192.168.42.112",
        "ADB discovery extracts the phone's routable Wi-Fi address without using VPN tunnel addresses"
    )
    try expectEqual(
        CompanionEndpointSelectionPolicy.source(
            hasBonjour: true,
            hasRoutedAddress: true,
            routedSessionActive: false
        ),
        .bonjour,
        "Bonjour remains the preferred same-link endpoint"
    )
    try expectEqual(
        CompanionEndpointSelectionPolicy.source(
            hasBonjour: false,
            hasRoutedAddress: true,
            routedSessionActive: false
        ),
        .routed,
        "a paired phone on a routed subnet remains reachable through its authenticated fallback endpoint"
    )
    try expectEqual(
        CompanionEndpointSelectionPolicy.source(
            hasBonjour: true,
            hasRoutedAddress: true,
            routedSessionActive: true
        ),
        .routed,
        "an active routed session stays stable instead of switching endpoints underneath six TLS channels"
    )
    print("PASS routed Companion fallback selects stable authenticated endpoints")

    var companionFailover = CompanionEndpointFailoverState()
    try expectEqual(
        companionFailover.source(
            peerID: "paired-s24",
            hasBonjour: true,
            hasRoutedAddress: true,
            routedSessionActive: false
        ),
        .bonjour,
        "a fresh session prefers Bonjour"
    )
    companionFailover.recordFailure(peerID: "paired-s24", source: .bonjour)
    try expectEqual(
        companionFailover.source(
            peerID: "paired-s24",
            hasBonjour: true,
            hasRoutedAddress: true,
            routedSessionActive: false
        ),
        .routed,
        "a failed stale Bonjour endpoint falls back to the last authenticated routed address"
    )
    companionFailover.recordSuccess(peerID: "paired-s24", source: .routed)
    try expectEqual(
        companionFailover.source(
            peerID: "paired-s24",
            hasBonjour: true,
            hasRoutedAddress: true,
            routedSessionActive: false
        ),
        .routed,
        "a healthy routed session remains stable while Bonjour is stale"
    )
    companionFailover.recordFailure(peerID: "paired-s24", source: .routed)
    try expectEqual(
        companionFailover.source(
            peerID: "paired-s24",
            hasBonjour: true,
            hasRoutedAddress: true,
            routedSessionActive: false
        ),
        .bonjour,
        "a failed routed address returns to Bonjour instead of retrying one dead endpoint forever"
    )
    print("PASS Companion endpoint failover alternates stale Bonjour and routed addresses")

    let routes = CapabilityResolver.routes(
        for: [
            TransportSnapshot(
                kind: .companionLAN,
                isConnected: true,
                capabilities: [.screenCapture, .files, .notifications]
            ),
            TransportSnapshot(
                kind: .usbADB,
                isConnected: true,
                capabilities: [.screenCapture, .inputInjection]
            ),
        ]
    )
    try expectEqual(
        routes[.screenCapture],
        .usbADB,
        "capability resolver routes shared features through the preferred transport"
    )
    try expectEqual(
        routes[.files],
        .companionLAN,
        "capability resolver retains companion-only features"
    )
    print("PASS CapabilityResolver merges connected transport capabilities")

    try expectEqual(
        EnhancedPositionalInputRoutingPolicy.backend(
            deviceName: "samsung SM-S928B"
        ),
        .scrcpy,
        "Samsung positional input stays on the continuous scrcpy control stream while the interactive blackout keeps display 0 awake"
    )
    try expectEqual(
        EnhancedPositionalInputRoutingPolicy.backend(
            deviceName: "Pixel 10 Pro"
        ),
        .scrcpy,
        "unaffected devices retain the preferred enhanced input route"
    )

    var samsungGesture = EnhancedADBTouchAccumulator()
    try expectEqual(
        samsungGesture.handle(.down, pointerID: 7, x: 0.25, y: 0.40),
        nil,
        "ADB touch starts without launching a shell command"
    )
    try expectEqual(
        samsungGesture.handle(.up, pointerID: 7, x: 0.251, y: 0.402),
        .tap(x: 0.251, y: 0.402),
        "a stationary touch becomes one physical-display tap"
    )
    _ = samsungGesture.handle(.down, pointerID: 8, x: 0.80, y: 0.50)
    _ = samsungGesture.handle(.move, pointerID: 8, x: 0.55, y: 0.50)
    try expectEqual(
        samsungGesture.handle(.up, pointerID: 8, x: 0.20, y: 0.50),
        .swipe(fromX: 0.80, fromY: 0.50, toX: 0.20, toY: 0.50, durationMilliseconds: 120),
        "a dragged touch becomes one non-cancelling physical-display swipe"
    )
    print("PASS enhanced Samsung positional input avoids the non-interactive scrcpy mirror display")

    var blackout = InteractiveDisplayBlackoutStateMachine()
    try expectEqual(blackout.handle(.controlReady), [], "blackout waits for the first frame")
    try expectEqual(
        blackout.handle(.firstFrame),
        [.applyInteractiveBlackout, .startPhysicalDisplayMonitoring],
        "blackout keeps Android interactive while making the OLED panel black"
    )
    try expectEqual(blackout.presentation, .mirroring, "interactive blackout keeps the mirror usable")
    try expectEqual(
        blackout.handle(.physicalDisplayChanged(.off)),
        [.revealPhysicalDisplay],
        "a physical power-button press reveals the phone screen"
    )
    try expectEqual(
        blackout.presentation,
        .physicalDeviceActive,
        "the Mac blocks mirrored input while the phone is being used physically"
    )
    try expectEqual(
        blackout.handle(.physicalDisplayChanged(.off)),
        [],
        "one power transition cannot retrigger before the display is on"
    )
    _ = blackout.handle(.physicalDisplayChanged(.on))
    try expectEqual(
        blackout.handle(.physicalDisplayChanged(.off)),
        [.applyInteractiveBlackout],
        "the next power-button press restores the interactive black panel"
    )
    _ = blackout.handle(.physicalDisplayChanged(.on))
    try expectEqual(blackout.presentation, .mirroring, "the mirror resumes after the phone panel is black")
    try expectEqual(
        blackout.handle(.stopped),
        [.restorePhysicalDisplay, .stopPhysicalDisplayMonitoring],
        "closing the session restores the user's display brightness"
    )
    print("PASS interactive OLED blackout preserves Samsung input and power-button interlock")

    let identity = DeviceIdentity(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        displayName: "Galaxy Fold",
        publicKeyFingerprint: Data(repeating: 0x5A, count: 32),
        pairedTransports: [.usbADB, .companionLAN]
    )
    var session = DeviceSessionModel(identity: identity)
    try session.connect(
        using: [
            TransportSnapshot(
                kind: .usbADB,
                isConnected: true,
                capabilities: [.screenCapture, .inputInjection]
            ),
            TransportSnapshot(
                kind: .companionLAN,
                isConnected: true,
                capabilities: [.screenCapture, .notifications]
            ),
        ]
    )
    try session.updateTransport(
        TransportSnapshot(
            kind: .usbADB,
            isConnected: false,
            capabilities: [.screenCapture, .inputInjection]
        )
    )
    try expectEqual(
        session.route(for: .screenCapture),
        .companionLAN,
        "device session falls back from USB ADB to companion LAN"
    )
    try expectEqual(
        session.state,
        .degraded,
        "device session reports degraded state after transport fallback"
    )
    print("PASS DeviceSessionModel falls back to companion LAN")

    let transferDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GalaxyBridgeSpec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: transferDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: transferDirectory) }

    let transferManifest = TransferManifest(
        transferID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        relativeName: "GalaxyBridge.txt",
        size: 12,
        mimeType: "text/plain",
        sha256: Data([
            0x21, 0x5C, 0xFF, 0xB5, 0x58, 0x4B, 0x6F, 0x7E,
            0x61, 0x3E, 0x24, 0x76, 0x4B, 0x83, 0x6A, 0x17,
            0x9F, 0x43, 0x87, 0x1F, 0xAE, 0x6E, 0xA3, 0x91,
            0xA8, 0x87, 0x8B, 0xCE, 0x05, 0xD0, 0xD3, 0x17,
        ])
    )
    var firstAssembler = try TransferAssembler(
        manifest: transferManifest,
        destinationDirectory: transferDirectory
    )
    try firstAssembler.append(Data("Galaxy".utf8), at: 0)
    var resumedAssembler = try TransferAssembler(
        manifest: transferManifest,
        destinationDirectory: transferDirectory
    )
    try expectEqual(
        resumedAssembler.confirmedOffset,
        6,
        "transfer assembler resumes from the existing part file"
    )
    try resumedAssembler.append(Data("Bridge".utf8), at: 6)
    try expectEqual(
        try Data(
            contentsOf: transferDirectory.appendingPathComponent("GalaxyBridge.txt.part")
        ),
        Data("GalaxyBridge".utf8),
        "transfer assembler appends chunks at the confirmed offset"
    )
    let completedFile = try resumedAssembler.finalize()
    try expectEqual(
        try Data(contentsOf: completedFile),
        Data("GalaxyBridge".utf8),
        "transfer assembler verifies and promotes a resumed transfer"
    )
    print("PASS TransferAssembler resumes and verifies transfers")

    let pairingPayload = PairingPayload(
        version: 1,
        hostID: UUID(uuidString: "12345678-1234-5678-90AB-1234567890AB")!,
        addresses: ["192.168.42.10", "galaxybridge.local"],
        port: 47_920,
        token: Data(repeating: 0xAB, count: 32),
        publicKeyFingerprint: Data(repeating: 0xCD, count: 32),
        expiresAt: Date(timeIntervalSince1970: 220)
    )
    let pairingURL = try PairingQRCode.encode(pairingPayload)
    let decodedPairingPayload = try PairingQRCode.decode(
        pairingURL,
        now: Date(timeIntervalSince1970: 100)
    )
    try expectEqual(
        decodedPairingPayload,
        pairingPayload,
        "pairing QR round-trips authenticated connection data"
    )
    print("PASS PairingQRCode round-trips pairing data")

    let shortTokenPayload = PairingPayload(
        version: 1,
        hostID: pairingPayload.hostID,
        addresses: pairingPayload.addresses,
        port: pairingPayload.port,
        token: Data(repeating: 0xAB, count: 31),
        publicKeyFingerprint: pairingPayload.publicKeyFingerprint,
        expiresAt: pairingPayload.expiresAt
    )
    try expectThrows(
        PairingQRCodeError.invalidField("token"),
        "pairing QR requires an exact 256-bit token"
    ) {
        _ = try PairingQRCode.encode(shortTokenPayload)
    }
    let longLivedPayload = PairingPayload(
        version: 1,
        hostID: pairingPayload.hostID,
        addresses: pairingPayload.addresses,
        port: pairingPayload.port,
        token: pairingPayload.token,
        publicKeyFingerprint: pairingPayload.publicKeyFingerprint,
        expiresAt: Date(timeIntervalSince1970: 221)
    )
    let longLivedURL = try PairingQRCode.encode(longLivedPayload)
    try expectThrows(
        PairingQRCodeError.invalidField("exp"),
        "pairing QR refuses a token lifetime beyond 120 seconds"
    ) {
        _ = try PairingQRCode.decode(longLivedURL, now: Date(timeIntervalSince1970: 100))
    }
    print("PASS PairingQRCode enforces token strength and TTL")

    let selectedPairingAddresses = PairingAddressSelector.select(
        candidates: [
            PairingAddressCandidate(interfaceName: "utun9", address: "fe80::9178:9fed:b030:64a8%utun9"),
            PairingAddressCandidate(interfaceName: "en0", address: "fe80::4a1:55a8:d6c3:52b1%en0"),
            PairingAddressCandidate(interfaceName: "awdl0", address: "fe80::3075:b8ff:fe04:fb5f%awdl0"),
            PairingAddressCandidate(interfaceName: "en0", address: "192.168.42.48"),
            PairingAddressCandidate(interfaceName: "llw0", address: "fe80::3075:b8ff:fe04:fb5f%llw0"),
            PairingAddressCandidate(interfaceName: "bridge100", address: "169.254.10.20"),
            PairingAddressCandidate(interfaceName: "en0", address: "fd4d:4764:23e0:971d:c3b:f1e6:1eda:995e"),
            PairingAddressCandidate(interfaceName: "en0", address: "192.168.42.48"),
            PairingAddressCandidate(interfaceName: "utun0", address: "198.18.0.1"),
        ],
        hostname: "MacBook-Pro.local"
    )
    try expectEqual(
        selectedPairingAddresses,
        [
            "192.168.42.48",
            "fd4d:4764:23e0:971d:c3b:f1e6:1eda:995e",
            "169.254.10.20",
            "fe80::4a1:55a8:d6c3:52b1%en0",
            "MacBook-Pro.local",
        ],
        "pairing addresses exclude VPN and peer-to-peer interfaces"
    )
    try expectEqual(
        PairingAddressSelector.select(
            candidates: (0 ..< 12).map {
                PairingAddressCandidate(interfaceName: "en\($0)", address: "10.0.0.\($0 + 1)")
            },
            hostname: "MacBook-Pro.local"
        ).count,
        PairingQRCode.maximumAddressCount,
        "pairing addresses are capped to the QR contract"
    )
    try expectEqual(
        PairingAddressSelector.select(candidates: [], hostname: "MacBook-Pro.local"),
        ["MacBook-Pro.local"],
        "pairing addresses retain a hostname fallback"
    )
    print("PASS PairingAddressSelector publishes bounded LAN-reachable endpoints")

    let macPairingKey = P256.Signing.PrivateKey()
    let phonePairingKey = P256.Signing.PrivateKey()
    let pairingTranscript = PairingTranscript.make(
        token: pairingPayload.token,
        clientNonce: Data(repeating: 0x11, count: 32),
        serverNonce: Data(repeating: 0x22, count: 32),
        macPublicKey: macPairingKey.publicKey.x963Representation,
        androidPublicKey: phonePairingKey.publicKey.x963Representation
    )
    let pairingSignature = try macPairingKey.signature(for: pairingTranscript).derRepresentation
    try expectEqual(
        try PairingTranscript.verify(
            signatureDER: pairingSignature,
            transcript: pairingTranscript,
            publicKeyX963: macPairingKey.publicKey.x963Representation
        ),
        true,
        "pairing transcript accepts the bound identity signature"
    )
    let tamperedTranscript = PairingTranscript.make(
        token: pairingPayload.token,
        clientNonce: Data(repeating: 0x11, count: 32),
        serverNonce: Data(repeating: 0x23, count: 32),
        macPublicKey: macPairingKey.publicKey.x963Representation,
        androidPublicKey: phonePairingKey.publicKey.x963Representation
    )
    try expectEqual(
        try PairingTranscript.verify(
            signatureDER: pairingSignature,
            transcript: tamperedTranscript,
            publicKeyX963: macPairingKey.publicKey.x963Representation
        ),
        false,
        "pairing transcript rejects nonce substitution"
    )
    print("PASS PairingTranscript cryptographically binds both identities and nonces")

    let pairingHostID = "12345678-1234-5678-90ab-1234567890ab"
    let pairingDeviceID = "galaxy-s24-ultra"
    let pairingSessionID = "pairing-session-42"
    let commitTranscript = PairingTranscript.makeCommit(
        token: pairingPayload.token,
        clientNonce: Data(repeating: 0x11, count: 32),
        serverNonce: Data(repeating: 0x22, count: 32),
        macPublicKey: macPairingKey.publicKey.x963Representation,
        androidPublicKey: phonePairingKey.publicKey.x963Representation,
        hostID: pairingHostID,
        deviceID: pairingDeviceID,
        sessionID: pairingSessionID
    )
    let commitSignature = try macPairingKey.signature(for: commitTranscript).derRepresentation
    try expectEqual(
        try PairingTranscript.verify(
            signatureDER: commitSignature,
            transcript: commitTranscript,
            publicKeyX963: macPairingKey.publicKey.x963Representation
        ),
        true,
        "pairing commit accepts the Mac signature bound to both device IDs and the session"
    )
    let substitutedCommit = PairingTranscript.makeCommit(
        token: pairingPayload.token,
        clientNonce: Data(repeating: 0x11, count: 32),
        serverNonce: Data(repeating: 0x22, count: 32),
        macPublicKey: macPairingKey.publicKey.x963Representation,
        androidPublicKey: phonePairingKey.publicKey.x963Representation,
        hostID: pairingHostID,
        deviceID: pairingDeviceID,
        sessionID: "substituted-session"
    )
    try expectEqual(
        try !PairingTranscript.verify(
            signatureDER: commitSignature,
            transcript: substitutedCommit,
            publicKeyX963: macPairingKey.publicKey.x963Representation
        ),
        true,
        "pairing commit rejects session substitution"
    )
    let acknowledgementTranscript = PairingTranscript.makeCommitAcknowledgement(
        commitTranscript: commitTranscript,
        commitSignature: commitSignature
    )
    let acknowledgementSignature = try phonePairingKey.signature(for: acknowledgementTranscript).derRepresentation
    try expectEqual(
        try PairingTranscript.verify(
            signatureDER: acknowledgementSignature,
            transcript: acknowledgementTranscript,
            publicKeyX963: phonePairingKey.publicKey.x963Representation
        ),
        true,
        "pairing acknowledgement proves that Android accepted the exact signed commit"
    )
    print("PASS two-phase pairing commit binds token, nonces, identities, session, and acknowledgement")

    let adbSerial = "R5CX123456A"
    let hostID = "5A67F995-2B6B-43EF-91F3-82822F69C05F"
    let adbNonce = Data(repeating: 0xA5, count: 32)
    let adbTranscript = ADBBindingTranscript.make(
        hostID: hostID,
        adbSerial: adbSerial,
        nonce: adbNonce,
        androidPublicKey: phonePairingKey.publicKey.x963Representation
    )
    let adbSignature = try phonePairingKey.signature(for: adbTranscript).derRepresentation
    try expectEqual(
        try ADBBindingTranscript.verify(
            signatureDER: adbSignature,
            hostID: hostID,
            adbSerial: adbSerial,
            nonce: adbNonce,
            androidPublicKey: phonePairingKey.publicKey.x963Representation
        ),
        true,
        "ADB binding signature must verify"
    )
    try expectEqual(
        try !ADBBindingTranscript.verify(
            signatureDER: adbSignature,
            hostID: hostID,
            adbSerial: "tampered",
            nonce: adbNonce,
            androidPublicKey: phonePairingKey.publicKey.x963Representation
        ),
        true,
        "ADB binding must reject a different serial"
    )
    print("PASS ADBBindingTranscript binds host, serial, nonce, and Android identity")

    let authenticationTranscript = SessionAuthenticationTranscript.make(
        deviceID: "mac-device",
        sessionID: "session-1",
        nonce: Data(repeating: 0x44, count: 32),
        timestampUnixSeconds: 123_456,
        identityPublicKey: macPairingKey.publicKey.x963Representation
    )
    let authenticationSignature = try macPairingKey.signature(for: authenticationTranscript).derRepresentation
    try expectEqual(
        try PairingTranscript.verify(
            signatureDER: authenticationSignature,
            transcript: authenticationTranscript,
            publicKeyX963: macPairingKey.publicKey.x963Representation
        ),
        true,
        "session authentication accepts a fresh signed transcript"
    )
    print("PASS SessionAuthenticationTranscript binds the TLS session identity")

    let unsafeManifest = TransferManifest(
        transferID: UUID(),
        relativeName: "../outside.txt",
        size: 0,
        mimeType: "text/plain",
        sha256: Data(SHA256.hash(data: Data()))
    )
    try expectThrows(
        TransferAssemblerError.invalidRelativeName("../outside.txt"),
        "transfer assembler rejects path traversal"
    ) {
        _ = try TransferAssembler(
            manifest: unsafeManifest,
            destinationDirectory: transferDirectory
        )
    }
    print("PASS TransferAssembler rejects unsafe relative names")

    var clipboardSuppressor = ClipboardLoopSuppressor(
        localDeviceID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        capacity: 16
    )
    let localClipboard = clipboardSuppressor.markPublished(Data("local".utf8))
    try expectEqual(
        clipboardSuppressor.shouldAccept(localClipboard),
        false,
        "clipboard suppressor rejects its own publication"
    )
    let remoteClipboard = ClipboardItemIdentity(
        originDeviceID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        sequence: 7,
        contentSHA256: Data(SHA256.hash(data: Data("remote".utf8)))
    )
    try expectEqual(
        clipboardSuppressor.shouldAccept(remoteClipboard),
        true,
        "clipboard suppressor accepts a new remote item"
    )
    try expectEqual(
        clipboardSuppressor.shouldAccept(remoteClipboard),
        false,
        "clipboard suppressor rejects a replayed remote item"
    )
    print("PASS ClipboardLoopSuppressor prevents local and replay loops")

    let geometry = DisplayGeometry(pixelWidth: 2_208, pixelHeight: 1_768)
    try expectEqual(
        NormalizedPoint(x: 1.25, y: -0.25).pixelPoint(in: geometry),
        PixelPoint(x: 2_207, y: 0),
        "coordinate transform clamps normalized input to display bounds"
    )
    try expectEqual(
        NormalizedPoint(x: 0.5, y: 0.5).pixelPoint(in: geometry),
        PixelPoint(x: 1_104, y: 884),
        "coordinate transform maps the Fold midpoint"
    )
    print("PASS NormalizedPoint transforms and clamps input")

    let retention = CacheRetentionPolicy(retention: 30 * 24 * 60 * 60)
    let now = Date(timeIntervalSince1970: 4_000_000)
    try expectEqual(
        retention.isExpired(
            createdAt: now.addingTimeInterval(-(30 * 24 * 60 * 60) - 1),
            now: now
        ),
        true,
        "cache retention expires content older than 30 days"
    )
    try expectEqual(
        retention.isExpired(createdAt: now.addingTimeInterval(-60), now: now),
        false,
        "cache retention keeps recent content"
    )
    print("PASS CacheRetentionPolicy enforces bounded local history")

    let adbDevices = ADBDeviceParser.parse(
        """
        List of devices attached
        R5CX1234ABC\tdevice product:e3qxxx model:SM_S928B device:e3q transport_id:1
        192.168.42.20:5555\tunauthorized transport_id:2

        """
    )
    try expectEqual(adbDevices.count, 2, "ADB parser keeps all reported devices")
    try expectEqual(adbDevices[0].serial, "R5CX1234ABC", "ADB parser reads USB serial")
    try expectEqual(adbDevices[0].model, "SM_S928B", "ADB parser reads model metadata")
    try expectEqual(adbDevices[0].state, .device, "ADB parser reads ready state")
    try expectEqual(adbDevices[1].state, .unauthorized, "ADB parser preserves authorization state")
    let mdnsDevice = ADBDeviceParser.parse("adb-PHONE-key._adb-tls-connect._tcp\tdevice model:SM_S928B")
    try expectEqual(mdnsDevice.first?.transport, .wirelessADB, "Bonjour ADB serials are wireless, never USB")
    print("PASS ADBDeviceParser parses long device listings")

    var epochTracker = DisplayEpochTracker()
    let folded = DisplayDescriptor(width: 904, height: 2_316, rotationDegrees: 0, displayID: 0)
    let unfolded = DisplayDescriptor(width: 2_208, height: 1_768, rotationDegrees: 0, displayID: 0)
    try expectEqual(epochTracker.observe(folded), 1, "first display starts epoch one")
    try expectEqual(epochTracker.observe(folded), 1, "unchanged display keeps decoder epoch")
    try expectEqual(epochTracker.observe(unfolded), 2, "Fold transition increments decoder epoch")
    print("PASS DisplayEpochTracker detects Fold/display changes")

    let scrcpyConfiguration = ScrcpyLaunchConfiguration(scid: 0x12AB34CD, videoCodec: .h265)
    try expectEqual(scrcpyConfiguration.socketName, "scrcpy_12ab34cd", "scrcpy socket name")
    try expectEqual(
        ScrcpyLaunchConfiguration.serverSHA256Hex,
        ProcessInfo.processInfo.environment["GB_EXPECTED_SCRCPY_SHA"] ?? "",
        "scrcpy 4.1 server artifact checksum is pinned"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("video_codec=h265"),
        true,
        "scrcpy launch requests HEVC"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("tunnel_forward=true"),
        true,
        "scrcpy launch matches adb forward direction"
    )
    let reverseScrcpyConfiguration = ScrcpyLaunchConfiguration(scid: 0x12AB34CC, tunnelForward: false)
    try expectEqual(
        reverseScrcpyConfiguration.serverArguments.contains("tunnel_forward=false"),
        true,
        "scrcpy launch can match an adb reverse listener"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("send_stream_meta=true"),
        true,
        "scrcpy 4.1 launch requests stream metadata"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("send_codec_meta=true"),
        false,
        "scrcpy 4.1 launch excludes the removed codec metadata option"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("power_on=false"),
        true,
        "enhanced mirror startup must not wake the physical phone display"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("keep_active=true"),
        true,
        "an active enhanced mirror must prevent Android inactivity lock without changing global settings"
    )
    let clipboardOnlyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34CF,
        videoEnabled: false,
        audioEnabled: false,
        sendDeviceMeta: false,
        keepActive: false,
        hideDeviceIME: false,
        uhidKeyboardEnabled: false
    )
    try expectEqual(
        clipboardOnlyConfiguration.serverArguments.contains("video=false"),
        true,
        "capture-free clipboard helper must not start a video encoder"
    )
    try expectEqual(
        clipboardOnlyConfiguration.serverArguments.contains("audio=false"),
        true,
        "capture-free clipboard helper must not start an audio encoder"
    )
    try expectEqual(
        clipboardOnlyConfiguration.serverArguments.contains("keep_active=false"),
        true,
        "capture-free clipboard helper must not keep the phone display awake"
    )
    try expectEqual(
        clipboardOnlyConfiguration.serverArguments.contains("display_ime_policy=hide"),
        false,
        "capture-free clipboard helper must leave Samsung Keyboard policy untouched"
    )
    try expectEqual(
        clipboardOnlyConfiguration.initialControlMessages.isEmpty,
        true,
        "capture-free clipboard helper must not register an unnecessary physical keyboard"
    )
    let wirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34CE,
        videoCodec: .h265,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h265).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h265).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h265).videoBitRate,
        videoKeyFrameIntervalSeconds: 1
    )
    try expectEqual(
        wirelessScrcpyConfiguration.serverArguments.contains("video_codec_options=i-frame-interval=1"),
        true,
        "wireless ADB can bound recovery without replacing the pinned scrcpy server"
    )
    let realtimeWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34CF,
        videoCodec: .h264,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true
    )
    try expectEqual(
        realtimeWirelessScrcpyConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0"
        ),
        true,
        "the isolated wireless realtime experiment preserves recovery options and requests priority zero"
    )
    let zeroFrameLatencyWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D3,
        videoCodec: .h264,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true,
        videoCodecZeroFrameLatency: true
    )
    try expectEqual(
        zeroFrameLatencyWirelessScrcpyConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0"
        ),
        true,
        "the isolated encoder-latency experiment adds the zero-frame request without replacing recovery options"
    )
    let operatingRateWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D9,
        videoCodec: .h264,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true,
        videoCodecZeroFrameLatency: true,
        videoCodecOperatingRate: 120
    )
    try expectEqual(
        operatingRateWirelessScrcpyConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0,operating-rate=120"
        ),
        true,
        "the isolated operating-rate experiment reaches Android MediaFormat without changing transport"
    )
    let repeatFrameWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34DA,
        videoCodec: .h264,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true,
        videoCodecZeroFrameLatency: true,
        videoCodecRepeatPreviousFrameAfterMicroseconds: 50_000
    )
    try expectEqual(
        repeatFrameWirelessScrcpyConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0,repeat-previous-frame-after:long=50000"
        ),
        true,
        "the static-response experiment overrides scrcpy's repeat interval with the MediaFormat long type"
    )
    let constantBitRateWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D4,
        videoCodec: .h264,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true,
        videoCodecZeroFrameLatency: true,
        videoCodecConstantBitRate: true
    )
    try expectEqual(
        constantBitRateWirelessScrcpyConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0,bitrate-mode=2"
        ),
        true,
        "the isolated CBR experiment adds only the supported constant-rate request"
    )
    let fastestComplexityWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D5,
        videoCodec: .h264,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true,
        videoCodecZeroFrameLatency: true,
        videoCodecFastestComplexity: true
    )
    try expectEqual(
        fastestComplexityWirelessScrcpyConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0,complexity=0"
        ),
        true,
        "the isolated complexity experiment requests the fastest supported hardware setting"
    )
    let baselineProfileWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D6,
        videoCodec: .h264,
        maxSize: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxSize,
        maxFPS: ScrcpyLaunchProfile.wirelessADB(codec: .h264).maxFPS,
        videoBitRate: ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true,
        videoCodecZeroFrameLatency: true,
        videoCodecFastestComplexity: true,
        videoCodecBaselineProfile: true
    )
    try expectEqual(
        baselineProfileWirelessScrcpyConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0,complexity=0,profile=1"
        ),
        true,
        "the isolated AVC profile experiment requests only the advertised baseline profile"
    )
    try expectEqual(
        ScrcpyLaunchProfile.wirelessADB(codec: .h265),
        ScrcpyLaunchProfile(
            maxSize: 1_920,
            maxFPS: 60,
            videoBitRate: 12_000_000,
            videoKeyFrameIntervalSeconds: 1,
            videoCodecRealtimePriority: true,
            videoCodecZeroFrameLatency: true,
            immediateVideoDelivery: true
        ),
        "wireless HEVC starts at the release 1920/60/12 Mbps profile"
    )
    try expectEqual(
        ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoBitRate,
        6_000_000,
        "wireless H.264 fallback starts at the hardware-verified 6 Mbps profile"
    )
    try expectEqual(
        ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoCodecConstantBitRate,
        true,
        "wireless H.264 uses the hardware-verified constant-rate profile"
    )
    try expectEqual(
        ScrcpyLaunchProfile.wirelessADB(codec: .h264).videoCodecFastestComplexity,
        false,
        "wireless release settings must not contain a model-specific encoder quirk"
    )
    let fold5ReleaseProfile = ScrcpyLaunchProfile.wirelessADB(codec: .h264)
    let fold5ReleaseConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D7,
        videoCodec: .h264,
        maxSize: fold5ReleaseProfile.maxSize,
        maxFPS: fold5ReleaseProfile.maxFPS,
        videoBitRate: fold5ReleaseProfile.videoBitRate,
        videoKeyFrameIntervalSeconds: fold5ReleaseProfile.videoKeyFrameIntervalSeconds,
        videoCodecRealtimePriority: fold5ReleaseProfile.videoCodecRealtimePriority,
        videoCodecZeroFrameLatency: fold5ReleaseProfile.videoCodecZeroFrameLatency,
        videoCodecConstantBitRate: fold5ReleaseProfile.videoCodecConstantBitRate,
        videoCodecFastestComplexity: fold5ReleaseProfile.videoCodecFastestComplexity
    )
    try expectEqual(
        fold5ReleaseConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0,bitrate-mode=2"
        ),
        true,
        "the Fold 5 release profile reaches scrcpy as CBR without the S24-only quirk"
    )
    let s24ReleaseProfile = ScrcpyLaunchProfile.wirelessADB(codec: .h264)
    let s24ReleaseConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D8,
        videoCodec: .h264,
        maxSize: s24ReleaseProfile.maxSize,
        maxFPS: s24ReleaseProfile.maxFPS,
        videoBitRate: s24ReleaseProfile.videoBitRate,
        videoKeyFrameIntervalSeconds: s24ReleaseProfile.videoKeyFrameIntervalSeconds,
        videoCodecRealtimePriority: s24ReleaseProfile.videoCodecRealtimePriority,
        videoCodecZeroFrameLatency: s24ReleaseProfile.videoCodecZeroFrameLatency,
        videoCodecConstantBitRate: s24ReleaseProfile.videoCodecConstantBitRate,
        videoCodecFastestComplexity: s24ReleaseProfile.videoCodecFastestComplexity
    )
    try expectEqual(
        s24ReleaseConfiguration.serverArguments.contains(
            "video_codec_options=i-frame-interval=1,priority=0,latency=0,bitrate-mode=2"
        ),
        true,
        "the same model-independent release profile reaches scrcpy on S24"
    )
    try expectEqual(
        ScrcpyLaunchProfile.selectedCodec(requested: .h265, isWirelessADB: true),
        .h264,
        "wireless ADB must use the motion-stable H.264 release codec"
    )
    try expectEqual(
        ScrcpyLaunchProfile.selectedCodec(requested: .h265, isWirelessADB: false),
        .h265,
        "USB must retain its existing HEVC release codec"
    )
    try expectEqual(
        ScrcpyLaunchProfile.wirelessADB(codec: .h264).immediateVideoDelivery,
        true,
        "wireless decoded frames must not accumulate a second playout buffer"
    )
    let reducedWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D0,
        videoCodec: .h264,
        maxSize: 1_280,
        maxFPS: 60,
        videoBitRate: 10_000_000,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true
    )
    try expectEqual(
        reducedWirelessScrcpyConfiguration.serverArguments.contains("max_size=1280"),
        true,
        "the isolated reduced-size experiment changes only the maximum encoded dimension"
    )
    let reducedRateWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D1,
        videoCodec: .h264,
        maxSize: 1_920,
        maxFPS: 60,
        videoBitRate: 8_000_000,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true
    )
    try expectEqual(
        reducedRateWirelessScrcpyConfiguration.serverArguments.contains("video_bit_rate=8000000"),
        true,
        "the isolated scrcpy rate experiment changes only the encoded video target"
    )
    let minimumRateWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D7,
        videoCodec: .h264,
        maxSize: 1_920,
        maxFPS: 60,
        videoBitRate: 6_000_000,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true,
        videoCodecZeroFrameLatency: true
    )
    try expectEqual(
        minimumRateWirelessScrcpyConfiguration.serverArguments.contains("video_bit_rate=6000000"),
        true,
        "the isolated minimum-rate experiment changes only the encoded video target"
    )
    let reducedFPSWirelessScrcpyConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x12AB34D2,
        videoCodec: .h264,
        maxSize: 1_920,
        maxFPS: 30,
        videoBitRate: 10_000_000,
        videoKeyFrameIntervalSeconds: 1,
        videoCodecRealtimePriority: true
    )
    try expectEqual(
        reducedFPSWirelessScrcpyConfiguration.serverArguments.contains("max_fps=30"),
        true,
        "the isolated scrcpy frame-rate experiment changes only the encoded frame-rate ceiling"
    )
    try expectEqual(
        ScrcpyLaunchProfile.usb,
        ScrcpyLaunchProfile(
            maxSize: 2_560,
            maxFPS: 60,
            videoBitRate: 20_000_000,
            videoKeyFrameIntervalSeconds: nil
        ),
        "USB keeps its existing 2560/60/20 Mbps profile"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains(where: { $0.hasPrefix("video_codec_options=") }),
        false,
        "USB keeps the pinned scrcpy encoder defaults"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("cleanup=true"),
        true,
        "scrcpy cleanup must restore display power when Galaxy Bridge stops"
    )
    print("PASS ScrcpyLaunchConfiguration pins the v4.1 enhanced session")

    let listedApplications = ScrcpyApplicationListParser.parse(
        """
        [server] INFO: List of apps:
         * Настройки                     com.android.settings
         - Samsung Notes                 com.samsung.android.app.notes
         - Очень длинное название приложения
                                        com.example.longlabel
        [server] INFO: Device disconnected
        """
    )
    try expectEqual(
        listedApplications,
        [
            ScrcpyApplication(
                packageName: "com.android.settings",
                label: "Настройки",
                isSystem: true
            ),
            ScrcpyApplication(
                packageName: "com.samsung.android.app.notes",
                label: "Samsung Notes",
                isSystem: false
            ),
            ScrcpyApplication(
                packageName: "com.example.longlabel",
                label: "Очень длинное название приложения",
                isSystem: false
            ),
        ],
        "scrcpy app list parser preserves localized labels, packages, and system flags"
    )
    try expectEqual(
        ScrcpyLaunchableComponentParser.parse(
            """
            com.android.settings/.Settings
            com.samsung.android.app.notes/com.samsung.android.app.notes.memolist.MemoListActivity
            unrelated output
            """
        ),
        [
            "com.android.settings": "com.android.settings/.Settings",
            "com.samsung.android.app.notes":
                "com.samsung.android.app.notes/com.samsung.android.app.notes.memolist.MemoListActivity",
        ],
        "launchable component parser rejects unrelated shell output"
    )
    let launchTarget = try ScrcpyApplicationTarget(packageName: "com.samsung.android.app.notes")
    let applicationConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x01020304,
        videoCodec: .h265,
        captureTarget: .virtualDisplay(width: 1_920, height: 1_080, dpi: 420),
        applicationTarget: launchTarget,
        cleanup: false
    )
    try expectEqual(
        ScrcpyControlMessage.resizeDisplay(width: 1_920, height: 1_080),
        Data([21, 0x07, 0x80, 0x04, 0x38]),
        "scrcpy 4.1 resize-display uses type 21 and unsigned big-endian dimensions"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains("flex_display=true"),
        true,
        "an independent application display opts into scrcpy client resizing"
    )
    let generalVirtualDisplayConfiguration = ScrcpyLaunchConfiguration(
        scid: 0x01020305,
        captureTarget: .virtualDisplay(width: 1_280, height: 720, dpi: 320)
    )
    try expectEqual(
        generalVirtualDisplayConfiguration.serverArguments.contains("flex_display=true"),
        false,
        "a general virtual desktop must remain fixed-size"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("flex_display=true"),
        false,
        "a physical mirror must remain fixed to its accepted device geometry"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains("vd_system_decorations=false"),
        true,
        "an independent app display must not start a competing Android launcher/taskbar"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains("vd_destroy_content=true"),
        true,
        "closing an independent display still cleans up only its hosted content"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains(
            "start_app=com.samsung.android.app.notes"
        ),
        false,
        "start-app is a scrcpy 4.1 control message, not a server option"
    )
    try expectEqual(
        applicationConfiguration.initialControlMessages,
        [
            ScrcpyUHIDKeyboard.createMessage,
            Data([16, 29]) + Data("com.samsung.android.app.notes".utf8),
        ],
        "an enhanced app window attaches the Mac keyboard before starting the selected package"
    )
    try expectEqual(
        scrcpyConfiguration.initialControlMessages,
        [ScrcpyUHIDKeyboard.createMessage],
        "the primary mirror exposes the Mac as a physical keyboard"
    )
    try expectEqual(
        ScrcpyUHIDKeyboard.reportDescriptor.count,
        63,
        "the pinned scrcpy 4.1 boot-keyboard descriptor remains byte-exact"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains("display_ime_policy=hide"),
        true,
        "an enhanced app window hides the redundant Android IME while Mac keyboard input is active"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("display_ime_policy=hide"),
        true,
        "the primary mirror also hides the redundant Android IME"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("clipboard_autosync=false"),
        true,
        "Galaxy Bridge explicitly polls the pinned clipboard channel so Android 16 cannot drop listener callbacks"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains("cleanup=false"),
        true,
        "an independent app window must not run primary-mirror display-power cleanup"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains("cleanup=true"),
        false,
        "closing an app window must not wake the physical phone display"
    )
    try expectEqual(
        applicationConfiguration.audioEnabled,
        false,
        "independent app windows must not create duplicate phone-audio pipelines"
    )
    try expectEqual(
        applicationConfiguration.serverArguments.contains("audio=false"),
        true,
        "scrcpy must omit the audio socket for independent app windows"
    )
    try expectEqual(
        scrcpyConfiguration.audioEnabled,
        true,
        "the primary mirror keeps the single phone-audio pipeline"
    )
    try expectEqual(
        scrcpyConfiguration.serverArguments.contains("audio=false"),
        false,
        "the primary mirror must continue forwarding phone audio"
    )
    try expectThrows(
        ScrcpyApplicationTargetError.invalidPackageName,
        "app package validation blocks server-option injection"
    ) {
        _ = try ScrcpyApplicationTarget(packageName: "com.example.bad start_app=other")
    }
    print("PASS scrcpy 4.1 application catalog and independent launch contract")

    let asciiTextInput = ScrcpyTextInputPlan.make(text: "GB123", clipboardSequence: 7)
    var expectedASCIIPaste = Data([9, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 5])
    expectedASCIIPaste.append(Data("GB123".utf8))
    try expectEqual(
        asciiTextInput.controlMessage,
        expectedASCIIPaste,
        "ASCII keyboard text sets the clipboard before an acknowledged physical-keyboard paste"
    )
    try expectEqual(
        asciiTextInput.clipboardEcho,
        Data("GB123".utf8),
        "ASCII keyboard text identifies the clipboard echo caused by pasting"
    )

    let unicodeText = "при🌉"
    let unicodeBytes = Data(unicodeText.utf8)
    let unicodeTextInput = ScrcpyTextInputPlan.make(text: unicodeText, clipboardSequence: 8)
    var expectedUnicodePaste = Data([9, 0, 0, 0, 0, 0, 0, 0, 8, 0])
    expectedUnicodePaste.append(contentsOf: [0, 0, 0, UInt8(unicodeBytes.count)])
    expectedUnicodePaste.append(unicodeBytes)
    try expectEqual(
        unicodeTextInput.controlMessage,
        expectedUnicodePaste,
        "Unicode keyboard text sets the clipboard before the physical-keyboard paste"
    )
    try expectEqual(
        unicodeTextInput.clipboardEcho,
        unicodeBytes,
        "Unicode keyboard text identifies the clipboard echo caused by pasting"
    )

    var virtualDisplayKeyboardQueue = ScrcpyKeyboardInputQueue(initialClipboardSequence: 40)
    let virtualDisplayEmission = try require(
        virtualDisplayKeyboardQueue.enqueueText(
            unicodeText,
            pasteMode: .acknowledgedDisplayKeycode
        ).first,
        "virtual-display text starts an addressed clipboard-paste transaction"
    )
    try expectEqual(
        virtualDisplayEmission.controlMessage[9],
        0,
        "independent app text waits for clipboard acknowledgement before injecting paste"
    )
    try expectEqual(
        virtualDisplayKeyboardQueue.acknowledgeClipboard(sequence: 40),
        ScrcpyControlMessage.clipboardPasteKeyMessages.map {
            ScrcpyKeyboardEmission(controlMessage: $0, clipboardEcho: nil)
        },
        "virtual-display paste uses the session-targeted scrcpy Ctrl-V keycode pair"
    )
    let virtualDisplaySettlement = try require(
        virtualDisplayKeyboardQueue.clipboardSettlementTicket,
        "virtual-display paste remains serialized through Android acknowledgement settlement"
    )
    try expectEqual(
        virtualDisplayKeyboardQueue.enqueueText(
            "2",
            pasteMode: .acknowledgedDisplayKeycode
        ),
        [],
        "a second virtual-display paste cannot replace the clipboard before settlement"
    )
    let nextVirtualDisplayEmission = try require(
        virtualDisplayKeyboardQueue.completeClipboardSettlement(
            ticket: try require(
                virtualDisplayKeyboardQueue.clipboardSettlementTicket,
                "queued virtual-display text refreshes the settlement ticket"
            )
        ).first,
        "settlement releases the next virtual-display text transaction"
    )
    try expectEqual(
        nextVirtualDisplayEmission.controlMessage[9],
        0,
        "every queued independent-app transaction waits for its own targeted UHID paste"
    )
    _ = virtualDisplaySettlement

    try expectEqual(
        ScrcpyTextInputRoutingPolicy.route(for: "abcXYZ_789"),
        .clipboardPaste,
        "printable ASCII uses the acknowledged atomic paste path so Samsung does not silently drop KeyCharacterMap letters"
    )
    try expectEqual(
        ScrcpyTextInputRoutingPolicy.route(for: "Привет_123"),
        .clipboardPaste,
        "Unicode text keeps the clipboard-paste route that preserves characters outside the SDK keyboard range"
    )

    var injectedTextEchoes = ScrcpyInjectedClipboardEchoSuppressor(capacity: 4)
    injectedTextEchoes.markInjected(unicodeBytes)
    try expectEqual(
        injectedTextEchoes.shouldForward(Data("unrelated".utf8)),
        true,
        "an unrelated phone clipboard update remains observable"
    )
    try expectEqual(
        !injectedTextEchoes.shouldForward(unicodeBytes),
        true,
        "the clipboard echo caused by Unicode keyboard injection is consumed once"
    )
    try expectEqual(
        injectedTextEchoes.shouldForward(unicodeBytes),
        true,
        "a later intentional copy of identical text is not suppressed forever"
    )

    var injectionWithoutDeviceEcho = ScrcpyInjectedClipboardEchoSuppressor(capacity: 4)
    injectionWithoutDeviceEcho.markInjected(Data("GBCLIP123".utf8))
    injectionWithoutDeviceEcho.discardInjected(Data("GBCLIP123".utf8))
    try expectEqual(
        injectionWithoutDeviceEcho.shouldForward(Data("GBCLIP123".utf8)),
        true,
        "a completed keyboard paste without a device echo cannot swallow the user's next intentional copy"
    )

    var keyboardQueue = ScrcpyKeyboardInputQueue(initialClipboardSequence: 20)
    let firstKeyboardEmission = keyboardQueue.enqueueText("A")
    try expectEqual(firstKeyboardEmission.count, 1, "the first keyboard text starts immediately")
    let returnKey = Data([0, 0, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0])
    try expectEqual(
        keyboardQueue.acknowledgeClipboard(sequence: 19),
        [],
        "an unrelated clipboard acknowledgement cannot advance keyboard input"
    )
    try expectEqual(
        keyboardQueue.acknowledgeClipboard(sequence: 20).map(\.controlMessage),
        ScrcpyUHIDKeyboard.pasteMessages,
        "clipboard acknowledgement injects a physical Ctrl-V chord that One UI accepts with its software keyboard hidden"
    )
    let firstSettlementTicket = try require(
        keyboardQueue.clipboardSettlementTicket,
        "acknowledged clipboard paste exposes a settlement ticket"
    )
    try expectEqual(keyboardQueue.enqueueText("B"), [], "typing during settlement stays queued")
    try expectEqual(keyboardQueue.enqueueText("C"), [], "continued typing coalesces during settlement")
    try expectEqual(
        keyboardQueue.enqueueControl(returnKey),
        [],
        "a keyboard command cannot overtake settling text"
    )
    let refreshedSettlementTicket = try require(
        keyboardQueue.clipboardSettlementTicket,
        "typing during settlement refreshes the quiet-period ticket"
    )
    try expect(
        refreshedSettlementTicket != firstSettlementTicket,
        "a new physical character invalidates the old Android paste settlement timer"
    )
    try expectEqual(
        keyboardQueue.completeClipboardSettlement(ticket: firstSettlementTicket),
        [],
        "a stale timer cannot replace the Android clipboard while the user is still typing"
    )
    let coalescedTextEmission = keyboardQueue.completeClipboardSettlement(ticket: refreshedSettlementTicket)
    try expectEqual(coalescedTextEmission.count, 1, "settlement releases coalesced text")
    try expectEqual(
        coalescedTextEmission.first?.clipboardEcho,
        Data("BC".utf8),
        "waiting printable text preserves exact order and content"
    )
    try expectEqual(
        keyboardQueue.acknowledgeClipboard(sequence: 21).map(\.controlMessage),
        ScrcpyUHIDKeyboard.pasteMessages,
        "every acknowledged text transaction pastes through the attached physical keyboard"
    )
    try expectEqual(
        keyboardQueue.completeClipboardSettlement(sequence: 21).map(\.controlMessage),
        [returnKey],
        "the following key command is released only after text paste completes"
    )
    print("PASS scrcpy keyboard text selects Unicode-safe injection without clipboard loops")

    try expectEqual(
        EnhancedTextInputRoutingPolicy.route(
            companionConnected: true,
            companionCapabilitiesKnown: true,
            companionAdvertisesInput: true,
            companionInputUnavailableReason: nil
        ),
        .companionAccessibility,
        "enhanced text must prefer the Unicode-capable Accessibility bridge when it is ready"
    )
    try expectEqual(
        EnhancedTextInputRoutingPolicy.route(
            companionConnected: true,
            companionCapabilitiesKnown: true,
            companionAdvertisesInput: true,
            companionInputUnavailableReason: "accessibility_service_disabled"
        ),
        .scrcpy,
        "contradictory advertised input with an unavailable reason must fail closed"
    )
    try expectEqual(
        EnhancedTextInputRoutingPolicy.route(
            companionConnected: false,
            companionCapabilitiesKnown: true,
            companionAdvertisesInput: true,
            companionInputUnavailableReason: nil
        ),
        .scrcpy,
        "enhanced text stays usable before the companion control channel connects"
    )
    try expectEqual(
        EnhancedTextInputRoutingPolicy.route(
            companionConnected: true,
            companionCapabilitiesKnown: false,
            companionAdvertisesInput: false,
            companionInputUnavailableReason: nil
        ),
        .scrcpy,
        "enhanced text does not assume accessibility before the first capability snapshot"
    )
    try expectEqual(
        EnhancedTextInputRoutingPolicy.route(
            companionConnected: true,
            companionCapabilitiesKnown: true,
            companionAdvertisesInput: false,
            companionInputUnavailableReason: nil
        ),
        .scrcpy,
        "a known capability snapshot that omits input must fail closed"
    )
    try expectEqual(
        [
            EnhancedTextInputRoutingPolicy.route(
                companionConnected: true,
                companionCapabilitiesKnown: true,
                companionAdvertisesInput: true,
                companionInputUnavailableReason: nil
            ),
            EnhancedTextInputRoutingPolicy.route(
                companionConnected: true,
                companionCapabilitiesKnown: true,
                companionAdvertisesInput: false,
                companionInputUnavailableReason: "accessibility_service_disabled"
            ),
            EnhancedTextInputRoutingPolicy.route(
                companionConnected: true,
                companionCapabilitiesKnown: true,
                companionAdvertisesInput: true,
                companionInputUnavailableReason: nil
            ),
            EnhancedTextInputRoutingPolicy.route(
                companionConnected: false,
                companionCapabilitiesKnown: true,
                companionAdvertisesInput: true,
                companionInputUnavailableReason: nil
            ),
        ],
        [.companionAccessibility, .scrcpy, .companionAccessibility, .scrcpy],
        "capability replacement, restoration and disconnect are evaluated from each raw snapshot"
    )
    print("PASS enhanced keyboard Companion eligibility uses conservative raw capability snapshots")

    let scrcpyWire = Data([
        0x68, 0x32, 0x36, 0x35,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x38, 0x00, 0x00, 0x09, 0x60,
        0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x01, 0x02, 0x03,
    ])
    var scrcpyDecoder = ScrcpyStreamDecoder(kind: .video, maxPayloadLength: 128 * 1_024)
    try expectEqual(
        try scrcpyDecoder.append(scrcpyWire.prefix(9)),
        [.codec(.h265)],
        "scrcpy fragmented stream header"
    )
    let scrcpyEvents = try scrcpyDecoder.append(scrcpyWire.dropFirst(9))
    try expectEqual(
        scrcpyEvents[0],
        .videoSession(ScrcpyVideoSession(width: 1_080, height: 2_400, clientResized: false)),
        "scrcpy video session metadata"
    )
    try expectEqual(
        scrcpyEvents[1],
        .packet(ScrcpyPacket(isConfiguration: true, isKeyFrame: false, presentationTimeUs: nil, payload: Data([1, 2, 3]))),
        "scrcpy packet metadata"
    )
    var sustainedScrcpyPacket = Data()
    var sustainedScrcpyHeader = UInt64(1).bigEndian
    withUnsafeBytes(of: &sustainedScrcpyHeader) { sustainedScrcpyPacket.append(contentsOf: $0) }
    var sustainedScrcpyLength = UInt32(64 * 1_024).bigEndian
    withUnsafeBytes(of: &sustainedScrcpyLength) { sustainedScrcpyPacket.append(contentsOf: $0) }
    sustainedScrcpyPacket.append(Data(repeating: 0x5A, count: 64 * 1_024))
    for _ in 0 ..< 512 {
        _ = try scrcpyDecoder.append(sustainedScrcpyPacket)
    }
    try expectEqual(
        scrcpyDecoder.retainedStorageByteCount,
        0,
        "fully consumed scrcpy frames must release their backing storage instead of retaining the complete session"
    )
    print("PASS ScrcpyStreamDecoder parses v4.1 codec, session, and packet metadata")

    var scrcpyDeviceMessages = ScrcpyDeviceMessageDecoder()
    try expectEqual(
        ScrcpyDeviceMessageDecoder.maximumMessageLength,
        1 << 18,
        "scrcpy v4.1 device-message maximum size"
    )
    try expectEqual(
        ScrcpyDeviceMessageDecoder.maximumClipboardLength,
        (1 << 18) - 5,
        "scrcpy v4.1 clipboard maximum excludes its five-byte header"
    )
    let fragmentedClipboard = Data([
        0x00,
        0x00, 0x00, 0x00, 0x0C,
        0x47, 0x61, 0x6C, 0x61, 0x78, 0x79,
        0x20, 0xF0, 0x9F, 0x8C, 0x89, 0x21,
    ])
    try expectEqual(
        try scrcpyDeviceMessages.append(fragmentedClipboard.prefix(3)),
        [],
        "scrcpy device-message decoder waits for a fragmented clipboard header"
    )
    try expectEqual(
        try scrcpyDeviceMessages.append(fragmentedClipboard.dropFirst(3).prefix(5)),
        [],
        "scrcpy device-message decoder waits for fragmented clipboard content"
    )
    try expectEqual(
        try scrcpyDeviceMessages.append(fragmentedClipboard.dropFirst(8)),
        [.clipboard(Data("Galaxy 🌉!".utf8))],
        "scrcpy device-message decoder restores UTF-8 clipboard content"
    )

    var coalescedDeviceMessages = ScrcpyDeviceMessageDecoder()
    let coalescedWire = Data([
        0x00, 0x00, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43,
        0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x02, 0x00, 0x2A, 0x00, 0x03, 0x10, 0x20, 0x30,
    ])
    try expectEqual(
        try coalescedDeviceMessages.append(coalescedWire),
        [
            .clipboard(Data("ABC".utf8)),
            .clipboardAcknowledgement(sequence: 0x0102_0304_0506_0708),
            .uhidOutput(id: 42, payload: Data([0x10, 0x20, 0x30])),
        ],
        "scrcpy device-message decoder consumes coalesced v4.1 messages"
    )
    let sustainedClipboardPayload = Data(repeating: 0x47, count: 64 * 1_024)
    var sustainedClipboardMessage = Data([0x00])
    var sustainedClipboardLength = UInt32(sustainedClipboardPayload.count).bigEndian
    withUnsafeBytes(of: &sustainedClipboardLength) { sustainedClipboardMessage.append(contentsOf: $0) }
    sustainedClipboardMessage.append(sustainedClipboardPayload)
    for _ in 0 ..< 512 {
        _ = try coalescedDeviceMessages.append(sustainedClipboardMessage)
    }
    try expectEqual(
        coalescedDeviceMessages.retainedStorageByteCount,
        0,
        "fully consumed scrcpy device messages must release their backing storage instead of retaining the complete session"
    )

    var oversizedDeviceMessages = ScrcpyDeviceMessageDecoder()
    try expectThrows(
        ScrcpyDeviceMessageError.invalidClipboardLength(262_144),
        "scrcpy oversized clipboard message is rejected from its header"
    ) {
        _ = try oversizedDeviceMessages.append(Data([0x00, 0x00, 0x04, 0x00, 0x00]))
    }
    var unknownDeviceMessages = ScrcpyDeviceMessageDecoder()
    try expectThrows(
        ScrcpyDeviceMessageError.unknownType(0x7F),
        "scrcpy unknown device message type terminates decoding safely"
    ) {
        _ = try unknownDeviceMessages.append(Data([0x7F]))
    }
    print("PASS ScrcpyDeviceMessageDecoder parses fragmented/coalesced v4.1 control replies safely")

    let receiveProbe = ScrcpyReceiveProbe()
    let receivePipeline = ScrcpyControlReceivePipeline(
        messageHandler: { receiveProbe.messages.append($0) },
        failureHandler: { receiveProbe.failures.append($0.localizedDescription) }
    )
    receivePipeline.consume(fragmentedClipboard.prefix(6))
    receivePipeline.consume(fragmentedClipboard.dropFirst(6))
    try expectEqual(
        receiveProbe.messages,
        [.clipboard(Data("Galaxy 🌉!".utf8))],
        "scrcpy control receive pipeline publishes a fragmented clipboard message"
    )
    receivePipeline.consume(Data([0x7F]))
    receivePipeline.consume(Data([0x00, 0, 0, 0, 1, 0x58]))
    try expectEqual(
        receiveProbe.messages,
        [.clipboard(Data("Galaxy 🌉!".utf8))],
        "scrcpy control receive pipeline stops dispatch after malformed input"
    )
    try expectEqual(
        receiveProbe.failures.count,
        1,
        "scrcpy control receive pipeline reports one terminal failure"
    )
    print("PASS ScrcpyControlReceivePipeline continuously dispatches and terminates once on malformed input")

    let firstClipboardID = ScrcpyClipboardIdentity.changeID(
        serial: "TESTPHONE01",
        sessionID: "session-a",
        sequence: 7,
        content: Data("same clipboard".utf8)
    )
    try expectEqual(
        ScrcpyClipboardIdentity.changeID(
            serial: "TESTPHONE01",
            sessionID: "session-a",
            sequence: 7,
            content: Data("same clipboard".utf8)
        ),
        firstClipboardID,
        "scrcpy clipboard identity is stable across repeated delivery"
    )
    try expectEqual(
        firstClipboardID.hasPrefix("scrcpy:TESTPHONE01:"),
        true,
        "scrcpy clipboard identity is scoped to the source device"
    )
    try expectEqual(
        ScrcpyClipboardIdentity.changeID(
            serial: "TESTPHONE01",
            sessionID: "session-a",
            sequence: 8,
            content: Data("same clipboard".utf8)
        ) == firstClipboardID,
        false,
        "scrcpy repeated clipboard content receives a new occurrence identity"
    )
    try expectEqual(
        ScrcpyClipboardIdentity.changeID(
            serial: "other",
            sessionID: "session-a",
            sequence: 7,
            content: Data("same clipboard".utf8)
        ) == firstClipboardID,
        false,
        "scrcpy clipboard identity does not collide across devices"
    )
    print("PASS ScrcpyClipboardIdentity provides stable per-device loop suppression IDs")

    var clipboardAgent = ScrcpyClipboardAgentDecoder()
    var clipboardAgentFrame = Data("GBC1".utf8)
    clipboardAgentFrame.append(ScrcpyClipboardContentKind.png.rawValue)
    clipboardAgentFrame.append(contentsOf: [0, 0, 0, 4, 0x89, 0x50, 0x4E, 0x47])
    let partialClipboardAgentMessages = try clipboardAgent.append(clipboardAgentFrame.prefix(6))
    precondition(partialClipboardAgentMessages == [])
    let completeClipboardAgentMessages = try clipboardAgent.append(clipboardAgentFrame.dropFirst(6))
    precondition(
        completeClipboardAgentMessages == [
            .init(kind: .png, content: Data([0x89, 0x50, 0x4E, 0x47]))
        ],
        "clipboard agent decoder must retain fragmented image frames"
    )
    print("PASS shell clipboard agent decoder accepts bounded fragmented image frames")

    let touchMessage = ScrcpyControlMessage.touch(
        action: .down,
        pointerID: UInt64.max,
        x: 540,
        y: 1_200,
        screenWidth: 1_080,
        screenHeight: 2_400,
        pressure: 1,
        actionButton: 1,
        buttons: 1
    )
    try expectEqual(touchMessage.count, 32, "scrcpy touch control size")
    try expectEqual(Array(touchMessage.prefix(2)), [2, 0], "scrcpy touch control type and action")

    let virtualFingerTouch = ScrcpyControlMessage.virtualFingerTouch(
        action: .down,
        x: 540,
        y: 1_200,
        screenWidth: 1_080,
        screenHeight: 2_400,
        pressure: 1
    )
    try expectEqual(virtualFingerTouch.count, 32, "scrcpy virtual-finger touch control size")
    try expectEqual(
        Array(virtualFingerTouch[2 ..< 10]),
        Array(repeating: UInt8.max, count: 7) + [UInt8.max - 1],
        "scrcpy virtual-finger touch uses the reserved -2 pointer id"
    )
    try expectEqual(
        Array(virtualFingerTouch.suffix(8)),
        Array(repeating: 0, count: 8),
        "scrcpy virtual-finger touch never advertises mouse action buttons"
    )

    let scrollMessage = ScrcpyControlMessage.scroll(
        x: 260,
        y: 1_026,
        screenWidth: 1_080,
        screenHeight: 1_920,
        horizontal: 16,
        vertical: -16,
        buttons: 1
    )
    try expectEqual(
        Array(scrollMessage),
        [
            3,
            0x00, 0x00, 0x01, 0x04,
            0x00, 0x00, 0x04, 0x02,
            0x04, 0x38,
            0x07, 0x80,
            0x7F, 0xFF,
            0x80, 0x00,
            0x00, 0x00, 0x00, 0x01,
        ],
        "scrcpy scroll control matches the v4.1 fixed-point layout"
    )
    try expectEqual(
        ScrcpyControlMessage.injectTextMessages("AБC", maximumPayloadLength: 3).map { Array($0) },
        [
            [1, 0, 0, 0, 3, 0x41, 0xD0, 0x91],
            [1, 0, 0, 0, 1, 0x43],
        ],
        "scrcpy direct text control preserves UTF-8 scalar boundaries while chunking"
    )
    try expectEqual(
        Array(ScrcpyControlMessage.getClipboard(copyKey: .copy)),
        [8, 1],
        "scrcpy copy command must request the Android clipboard after injecting KEYCODE_COPY"
    )
    try expectEqual(
        Array(ScrcpyControlMessage.getClipboard(copyKey: .cut)),
        [8, 2],
        "scrcpy cut command must request the Android clipboard after injecting KEYCODE_CUT"
    )
    try expectEqual(
        ScrcpyControlMessage.clipboardRequestMessages(copyKey: .copy).map { Array($0) },
        [[8, 1]],
        "scrcpy copy must use the server's atomic copy-and-read command"
    )
    try expectEqual(
        ScrcpyControlMessage.clipboardRequestMessages(copyKey: .cut).map { Array($0) },
        [[8, 2]],
        "scrcpy cut must use the server's atomic cut-and-read command"
    )
    try expectEqual(
        ScrcpyControlMessage.clipboardShortcutKeyMessages(copyKey: .copy).map { Array($0) },
        [
            [0, 0, 0, 0, 0, 31, 0, 0, 0, 0, 0, 0, 0x30, 0x00],
            [0, 1, 0, 0, 0, 31, 0, 0, 0, 0, 0, 0, 0x30, 0x00],
        ],
        "Samsung Chrome copy uses the Ctrl-C chord accepted by its virtual display"
    )
    print("PASS ScrcpyControlMessage emits the v4.1 control layout")

    let gamepadCreate = ScrcpyControlMessage.uhidCreate(
        id: 3,
        vendorID: 0x045E,
        productID: 0x028E,
        name: "Xbox",
        reportDescriptor: Data([1, 2, 3])
    )
    try expectEqual(
        Array(gamepadCreate),
        [12, 0, 3, 0x04, 0x5E, 0x02, 0x8E, 4, 88, 98, 111, 120, 0, 3, 1, 2, 3],
        "scrcpy UHID create layout"
    )
    let neutralGamepad = ScrcpyUHIDGamepadReport()
    try expectEqual(
        Array(neutralGamepad.data),
        [0, 128, 0, 128, 0, 128, 0, 128, 0, 0, 0, 0, 0, 0, 0],
        "neutral gamepad HID report"
    )
    let activeGamepad = ScrcpyUHIDGamepadReport(
        leftX: 1,
        leftY: -1,
        rightX: 0,
        rightY: 0.5,
        leftTrigger: 1,
        rightTrigger: 0.5,
        buttons: [.south, .leftShoulder],
        dpad: .upRight
    )
    try expectEqual(Array(activeGamepad.data.prefix(4)), [0xFF, 0xFF, 0, 0], "gamepad axis scaling")
    try expectEqual(Array(activeGamepad.data[8 ..< 15]), [0xFF, 0x7F, 0, 0x40, 0x41, 0, 2], "gamepad buttons and dpad")
    try expectEqual(
        Array(ScrcpyControlMessage.uhidInput(id: 3, report: neutralGamepad.data).prefix(5)),
        [13, 0, 3, 0, 15],
        "scrcpy UHID input layout"
    )
    try expectEqual(Array(ScrcpyControlMessage.uhidDestroy(id: 3)), [14, 0, 3], "scrcpy UHID destroy layout")
    print("PASS scrcpy 4.1 UHID gamepad messages and reports")

    let listedDisplays = ScrcpyDisplayParser.parse(
        """
        [server] INFO: List of displays:
            --display-id=0    (2208x1768)
            --display-id=2    (1920x1080)
        """
    )
    try expectEqual(
        listedDisplays,
        [ScrcpyDisplay(id: 0, width: 2_208, height: 1_768), ScrcpyDisplay(id: 2, width: 1_920, height: 1_080)],
        "scrcpy display list parser"
    )
    let secondaryDisplay = ScrcpyLaunchConfiguration(scid: 2, captureTarget: .display(id: 2))
    try expectEqual(secondaryDisplay.serverArguments.contains("display_id=2"), true, "scrcpy secondary display option")
    try expectEqual(
        secondaryDisplay.serverArguments.contains(where: { $0.hasPrefix("vd_system_decorations=") }),
        false,
        "physical display mirroring does not alter system decorations"
    )
    let virtualDisplay = ScrcpyLaunchConfiguration(
        scid: 3,
        captureTarget: .virtualDisplay(width: 1_920, height: 1_080, dpi: 420)
    )
    try expectEqual(
        virtualDisplay.serverArguments.contains("new_display=1920x1080/420"),
        true,
        "scrcpy virtual display option"
    )
    try expectEqual(
        virtualDisplay.serverArguments.contains("vd_system_decorations=true"),
        true,
        "a general-purpose virtual display keeps the Android launcher and navigation"
    )
    print("PASS scrcpy display enumeration and capture target options")

    let annexB = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB])
    try expectEqual(
        AnnexB.nalUnits(in: annexB),
        [Data([0x67, 0xAA]), Data([0x68, 0xBB])],
        "Annex-B parser finds mixed start-code lengths"
    )
    try expectEqual(
        Array(AnnexB.lengthPrefixedSample(from: annexB)),
        [0, 0, 0, 2, 0x67, 0xAA, 0, 0, 0, 2, 0x68, 0xBB],
        "Annex-B converter creates VideoToolbox length-prefixed samples"
    )
    print("PASS AnnexB prepares encoded frames for VideoToolbox")

    let cacheKey = SymmetricKey(size: .bits256)
    let sealedCacheValue = try EncryptedPayload.seal(
        Data("private notification".utf8),
        using: cacheKey,
        authenticatedData: Data("notifications/item-1".utf8)
    )
    try expectEqual(
        try EncryptedPayload.open(
            sealedCacheValue,
            using: cacheKey,
            authenticatedData: Data("notifications/item-1".utf8)
        ),
        Data("private notification".utf8),
        "AES-GCM cache payload round-trip"
    )
    try expectEqual(
        sealedCacheValue.combined.contains(Data("private notification".utf8)),
        false,
        "encrypted cache does not contain plaintext"
    )
    print("PASS EncryptedPayload protects cached content with AES-GCM")

    let notificationOnlySMS = CapabilityAccessResolver.resolve(
        capabilityCode: "CAPABILITY_SMS",
        availableCapabilities: [],
        unavailableReasons: ["CAPABILITY_SMS": "notification_actions_only"]
    )
    try expectEqual(
        notificationOnlySMS,
        .notificationActionsOnly,
        "SMS advertised as notification actions only cannot use direct protocol events"
    )
    try expectEqual(
        SMSDeliveryPolicy.allowsDirectSend(for: notificationOnlySMS),
        false,
        "notification-only SMS blocks direct sending"
    )
    let directSMS = CapabilityAccessResolver.resolve(
        capabilityCode: "CAPABILITY_SMS",
        availableCapabilities: ["CAPABILITY_SMS"],
        unavailableReasons: [:]
    )
    try expectEqual(
        SMSDeliveryPolicy.allowsDirectSend(for: directSMS),
        true,
        "direct SMS requires the capability to be explicitly advertised"
    )
    try expectEqual(
        CapabilityAccessResolver.resolve(
            capabilityCode: "CAPABILITY_SMS",
            availableCapabilities: [],
            unavailableReasons: [:]
        ),
        .unknown,
        "missing capability data stays unavailable until the phone advertises support"
    )
    try expectEqual(
        SMSPanelPresentationPolicy.mode(for: notificationOnlySMS),
        .notificationReplies,
        "notification-actions-only capability shows the notification reply explanation"
    )
    try expectEqual(
        SMSPanelPresentationPolicy.mode(for: .unavailable("notification_access_disabled")),
        .unavailable,
        "other unavailable reasons must not promise notification replies"
    )
    print("PASS SMS delivery follows the advertised companion capability")

    var protectedContent = ProtectedContentHeuristic(minimumBlackDuration: 1.5)
    try expectEqual(
        protectedContent.observe(uniformlyBlack: true, presentationTime: 10, epoch: 7),
        false,
        "one black frame is not enough to classify protected content"
    )
    try expectEqual(
        protectedContent.observe(uniformlyBlack: true, presentationTime: 11.49, epoch: 7),
        false,
        "black content below the dwell threshold remains visible"
    )
    try expectEqual(
        protectedContent.observe(uniformlyBlack: true, presentationTime: 11.5, epoch: 7),
        true,
        "sustained uniformly black capture uses a privacy-safe placeholder"
    )
    try expectEqual(
        protectedContent.observe(uniformlyBlack: false, presentationTime: 11.6, epoch: 7),
        false,
        "a visible frame immediately clears the conservative placeholder"
    )
    _ = protectedContent.observe(uniformlyBlack: true, presentationTime: 20, epoch: 7)
    try expectEqual(
        protectedContent.observe(uniformlyBlack: true, presentationTime: 22, epoch: 8),
        false,
        "a display epoch change starts a fresh protected-content observation window"
    )
    print("PASS ProtectedContentHeuristic requires sustained black frames and resets safely")

    var videoSurfacePublication = VideoSurfacePublicationState()
    try expectEqual(
        videoSurfacePublication.consume(protectedContentSuspected: false),
        VideoSurfacePublicationUpdate(hasFrame: true, protectedContentSuspected: nil),
        "the first decoded frame publishes readiness once"
    )
    for _ in 0 ..< 120 {
        try expectEqual(
            videoSurfacePublication.consume(protectedContentSuspected: false),
            VideoSurfacePublicationUpdate(hasFrame: nil, protectedContentSuspected: nil),
            "steady video frames must not invalidate the SwiftUI hierarchy"
        )
    }
    try expectEqual(
        videoSurfacePublication.consume(protectedContentSuspected: true),
        VideoSurfacePublicationUpdate(hasFrame: nil, protectedContentSuspected: true),
        "the protected-content transition must still publish"
    )
    try expectEqual(
        videoSurfacePublication.consume(protectedContentSuspected: false),
        VideoSurfacePublicationUpdate(hasFrame: nil, protectedContentSuspected: false),
        "visible content must publish removal of the placeholder"
    )
    print("PASS video surface publishes only semantic state transitions")

    var renderInvalidation = VideoSurfaceRenderInvalidationState()
    try expectEqual(
        renderInvalidation.request(),
        true,
        "the first delivered frame requests a Metal draw"
    )
    for _ in 0 ..< 120 {
        try expectEqual(
            renderInvalidation.request(),
            false,
            "frames arriving before the pending draw must coalesce"
        )
    }
    renderInvalidation.didDraw()
    try expectEqual(
        renderInvalidation.request(),
        true,
        "a frame after the completed draw schedules the next refresh"
    )
    print("PASS video surface coalesces redundant main-thread invalidations")

    var interlockPublication = ScreenInterlockPresentationPublicationState(
        initial: .waitingForFirstFrame
    )
    try expectEqual(
        interlockPublication.consume(.waitingForFirstFrame),
        nil,
        "the initial screen-interlock value must not be republished"
    )
    try expectEqual(
        interlockPublication.consume(.mirroring),
        .mirroring,
        "the first visible-frame transition must publish"
    )
    for _ in 0 ..< 120 {
        try expectEqual(
            interlockPublication.consume(.mirroring),
            nil,
            "steady decoded frames must not republish the interlock state"
        )
    }
    try expectEqual(
        interlockPublication.consume(.physicalDeviceActive),
        .physicalDeviceActive,
        "a physical-phone activation must still publish"
    )
    print("PASS screen interlock publishes only semantic presentation transitions")

    var mediaRetryGate = BoundedMediaRecoveryRetryGate()
    try expectEqual(
        mediaRetryGate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 7),
        7,
        "an exhausted dependency-recovery episode receives one bounded retry"
    )
    try expectEqual(
        mediaRetryGate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 8),
        8,
        "a second exhausted episode must not leave a live stream stuck forever"
    )
    for _ in 0..<1000 {
        try expectEqual(mediaRetryGate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 8),
                        nil, "polling an exhausted snapshot must not retry the same episode twice")
    }
    try expectEqual(mediaRetryGate.retryEpisode(state: 3, reason: 5, attempt: 2, episode: 9),
                    9, "native exhaustion remains authoritative if a request window was missed")
    _ = mediaRetryGate.retryEpisode(state: 1, reason: 0, attempt: 0, episode: 0)
    try expectEqual(
        mediaRetryGate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 9),
        nil,
        "healthy snapshots must not make a stale exhausted episode eligible again"
    )
    for episode: UInt64 in 10...50 {
        try expectEqual(mediaRetryGate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: episode),
                        episode, "a long live session may recover more than one outage")
    }
    print("PASS media recovery retries once per native-bounded exhausted episode")

    var wirelessVideoRecovery = WirelessADBVideoRecoveryGate()
    let delta = ScrcpyStreamEvent.packet(.init(
        isConfiguration: false,
        isKeyFrame: false,
        presentationTimeUs: 1,
        payload: Data([1])
    ))
    let keyFrame = ScrcpyStreamEvent.packet(.init(
        isConfiguration: false,
        isKeyFrame: true,
        presentationTimeUs: 2,
        payload: Data([2])
    ))
    let configuration = ScrcpyStreamEvent.packet(.init(
        isConfiguration: true,
        isKeyFrame: false,
        presentationTimeUs: nil,
        payload: Data([3])
    ))
    try expectEqual(wirelessVideoRecovery.shouldAdmit(delta), true, "healthy wireless deltas are admitted")
    try expectEqual(wirelessVideoRecovery.notePressure(on: delta), true, "first pressure opens one recovery episode")
    try expectEqual(wirelessVideoRecovery.notePressure(on: delta), false, "one pressure burst has one gap transition")
    try expectEqual(wirelessVideoRecovery.shouldAdmit(delta), false, "stale dependent frames are dropped after a gap")
    try expectEqual(wirelessVideoRecovery.shouldAdmit(configuration), true, "codec configuration survives recovery")
    try expectEqual(wirelessVideoRecovery.shouldAdmit(keyFrame), true, "a recovery keyframe may enter admission")
    try expectEqual(wirelessVideoRecovery.shouldAdmit(delta), false, "a merely observed keyframe does not reopen deltas")
    wirelessVideoRecovery.noteAdmitted(keyFrame)
    try expectEqual(wirelessVideoRecovery.shouldAdmit(delta), true, "an admitted keyframe closes the recovery episode")
    print("PASS wireless ADB video pressure drops stale deltas and recovers only at an admitted keyframe")
} catch {
    FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
    exit(1)
}
