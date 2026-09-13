import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeProtocol
import Testing
@testable import GalaxyBridgeMac

private final class BindingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_000)) {
        self.value = value
    }

    func now() -> Date { lock.withLock { value } }

    func advance(_ interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private final class BindingNonceSource: @unchecked Sendable {
    private let lock = NSLock()
    private var nextByte: UInt8 = 1

    func next() -> Data {
        lock.withLock {
            defer { nextByte &+= 1 }
            return Data(repeating: nextByte, count: 32)
        }
    }
}

private struct BindingLaunch: Equatable, Sendable {
    let serial: String
    let url: URL

    var nonce: Data {
        let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "nonce" })?.value ?? ""
        var base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64) ?? Data()
    }
}

private final class BindingLaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BindingLaunch] = []

    var launches: [BindingLaunch] { lock.withLock { stored } }

    func append(serial: String, url: URL) {
        lock.withLock { stored.append(.init(serial: serial, url: url)) }
    }
}

private final class BindingExhaustionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ADBBindingRecoveryExhaustion] = []

    var events: [ADBBindingRecoveryExhaustion] { lock.withLock { stored } }

    func append(_ event: ADBBindingRecoveryExhaustion) {
        lock.withLock { stored.append(event) }
    }
}

private final class BindingMemoryBackend: SecureRecordPersistenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private var storedFailWrites = false
    private var storedMainThreadAccessCount = 0
    private var writeGate: DispatchSemaphore?
    private var storedWriteIsWaiting = false

    var failWrites: Bool {
        get { lock.withLock { storedFailWrites } }
        set { lock.withLock { storedFailWrites = newValue } }
    }

    var mainThreadAccessCount: Int { lock.withLock { storedMainThreadAccessCount } }
    var writeIsWaiting: Bool { lock.withLock { storedWriteIsWaiting } }

    func pauseWrites() {
        lock.withLock { writeGate = DispatchSemaphore(value: 0) }
    }

    func releaseWrites() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            defer { writeGate = nil }
            return writeGate
        }
        gate?.signal()
    }

    private func key(service: String, account: String) -> String { "\(service)\u{0}\(account)" }

    func upsert(service: String, account: String, data: Data) throws {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            if Thread.isMainThread { storedMainThreadAccessCount += 1 }
            if writeGate != nil { storedWriteIsWaiting = true }
            return writeGate
        }
        gate?.wait()
        try lock.withLock {
            storedWriteIsWaiting = false
            if storedFailWrites { throw BindingTestError.persistence }
            records[key(service: service, account: account)] = data
        }
    }

    func read(service: String, account: String) throws -> Data? {
        lock.withLock {
            if Thread.isMainThread { storedMainThreadAccessCount += 1 }
            return records[key(service: service, account: account)]
        }
    }

    func accounts(service: String) throws -> [String] {
        let prefix = "\(service)\u{0}"
        return lock.withLock {
            records.keys.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        }
    }

    func delete(service: String, account: String) throws {
        _ = lock.withLock { records.removeValue(forKey: key(service: service, account: account)) }
    }
}

private actor BindingAsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var isOpen = false

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func arrivalCount() -> Int { arrivals }

    func releaseAll() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum BindingTestError: Error {
    case persistence
    case timedOut(String)
}

@MainActor
@Suite(.serialized)
struct ADBBindingRecoveryTests {
    private let policy = ADBBindingRecoveryPolicy(
        requestTimeout: 10,
        retryBackoffs: [5, 10],
        attemptLimit: 3
    )

    @Test
    func stableTopologyRetriesOnlyDroppedAliasWithFreshNonceAndConverges() async throws {
        let fixture = try makeFixture()
        let first = "192.168.42.40:39643"
        let second = "adb-TESTPHONE02._adb-tls-connect._tcp"
        let candidates = [
            fixture.candidate(serial: first),
            fixture.candidate(serial: second),
        ]

        fixture.binder.reconcile(candidates, in: fixture.session)
        try await waitUntil("two initial launches") { fixture.launcher.launches.count == 2 }
        let initial = fixture.launcher.launches
        _ = try await fixture.binder.accept(
            fixture.response(for: try #require(initial.first(where: { $0.serial == second }))),
            from: fixture.peer,
            in: fixture.session
        )

        fixture.clock.advance(10)
        fixture.binder.reconcile(candidates, in: fixture.session)
        #expect(fixture.launcher.launches.count == 2)
        fixture.clock.advance(5)
        fixture.binder.reconcile(candidates, in: fixture.session)
        try await waitUntil("retry launch") { fixture.launcher.launches.count == 3 }

        let retry = try #require(fixture.launcher.launches.last)
        #expect(retry.serial == first)
        #expect(retry.nonce != initial.first(where: { $0.serial == first })?.nonce)
        _ = try await fixture.binder.accept(
            fixture.response(for: retry),
            from: fixture.peer,
            in: fixture.session
        )

        fixture.clock.advance(100)
        let scheduledAfterSuccess = fixture.binder.reconcile(candidates, in: fixture.session)
        for task in scheduledAfterSuccess { await task.value }
        #expect(fixture.launcher.launches.count == 3)
        #expect(fixture.backend.mainThreadAccessCount == 0)
        #expect(try fixture.store.record(for: first)?.deviceID == fixture.peer.deviceID)
        #expect(try fixture.store.record(for: second)?.deviceID == fixture.peer.deviceID)
    }

    @Test
    func rejectsWrongSerialPeerKeySignatureAndExpiredOrRetiredNonce() async throws {
        let fixture = try makeFixture()
        let serial = "192.168.42.40:39643"
        let candidate = fixture.candidate(serial: serial)
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("initial launch") { fixture.launcher.launches.count == 1 }
        let launch = try #require(fixture.launcher.launches.first)

        var wrongSerial = try fixture.response(for: launch)
        wrongSerial.adbSerial = "wrong"
        #expect(try await fixture.binder.accept(wrongSerial, from: fixture.peer, in: fixture.session) == nil)

        let otherPeer = try makePeer(deviceID: "other")
        #expect(try await fixture.binder.accept(fixture.response(for: launch), from: otherPeer.peer, in: fixture.session) == nil)

        var wrongKey = try fixture.response(for: launch)
        wrongKey.identityPublicKey = otherPeer.peer.identityPublicKey
        await #expect(throws: ADBIdentityBindingError.self) {
            try await fixture.binder.accept(wrongKey, from: fixture.peer, in: fixture.session)
        }

        fixture.clock.advance(15)
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("second launch") { fixture.launcher.launches.count == 2 }
        let second = try #require(fixture.launcher.launches.last)
        var wrongSignature = try fixture.response(for: second)
        wrongSignature.signature = Data([0x30, 0x00])
        await #expect(throws: Error.self) {
            try await fixture.binder.accept(wrongSignature, from: fixture.peer, in: fixture.session)
        }

        fixture.clock.advance(20)
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("third launch") { fixture.launcher.launches.count == 3 }
        let third = try #require(fixture.launcher.launches.last)
        fixture.clock.advance(11)
        await #expect(throws: ADBIdentityBindingError.self) {
            try await fixture.binder.accept(fixture.response(for: third), from: fixture.peer, in: fixture.session)
        }

        fixture.binder.retryExhausted(in: fixture.session)
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("manual retry launch") { fixture.launcher.launches.count == 4 }
        let retired = try #require(fixture.launcher.launches.last)
        fixture.binder.retire(session: fixture.session)
        #expect(try await fixture.binder.accept(fixture.response(for: retired), from: fixture.peer, in: fixture.session) == nil)
        #expect(try fixture.store.record(for: serial) == nil)
    }

    @Test
    func backoffAndAttemptLimitReportExhaustionOnceThenLifecycleCanRetry() async throws {
        let fixture = try makeFixture()
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")

        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("attempt one") { fixture.launcher.launches.count == 1 }
        for (deadline, backoff, expectedCount) in [(10.0, 5.0, 2), (10.0, 10.0, 3)] {
            fixture.clock.advance(deadline)
            fixture.binder.reconcile([candidate], in: fixture.session)
            #expect(fixture.launcher.launches.count == expectedCount - 1)
            fixture.clock.advance(backoff)
            fixture.binder.reconcile([candidate], in: fixture.session)
            try await waitUntil("attempt \(expectedCount)") { fixture.launcher.launches.count == expectedCount }
        }

        fixture.clock.advance(10)
        fixture.binder.reconcile([candidate], in: fixture.session)
        fixture.binder.reconcile([candidate], in: fixture.session)
        #expect(fixture.launcher.launches.count == 3)
        #expect(fixture.exhaustions.events == [
            .init(serial: candidate.serial, peerID: fixture.peer.deviceID, attempts: 3),
        ])

        let nextSession = ADBBindingSession(companionID: fixture.session.companionID, generation: 8)
        fixture.binder.reconcile([candidate], in: nextSession)
        try await waitUntil("new generation attempt") { fixture.launcher.launches.count == 4 }
        #expect(fixture.launcher.launches.last?.serial == candidate.serial)
    }

    @Test
    func endpointLossAndGenerationReplacementRetireOldNonceWithoutLaunchStorms() async throws {
        let fixture = try makeFixture()
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")
        fixture.binder.reconcile([candidate], in: fixture.session)
        fixture.binder.reconcile([candidate], in: fixture.session)
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("single in-flight launch") { fixture.launcher.launches.count == 1 }
        let first = try #require(fixture.launcher.launches.first)

        fixture.binder.reconcile([], in: fixture.session)
        #expect(try await fixture.binder.accept(fixture.response(for: first), from: fixture.peer, in: fixture.session) == nil)

        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("endpoint reconnect launch") { fixture.launcher.launches.count == 2 }
        let reconnected = try #require(fixture.launcher.launches.last)
        let replacement = ADBBindingSession(companionID: fixture.session.companionID, generation: 9)
        fixture.binder.reconcile([candidate], in: replacement)
        try await waitUntil("replacement generation launch") { fixture.launcher.launches.count == 3 }
        #expect(try await fixture.binder.accept(fixture.response(for: reconnected), from: fixture.peer, in: fixture.session) == nil)
        #expect(try fixture.store.record(for: candidate.serial) == nil)
    }

    @Test
    func cancellationDuringHardwareProbeCannotLaunchRetiredChallenge() async throws {
        let probeGate = BindingAsyncGate()
        let fixture = try makeFixture(probe: { _ in
            await probeGate.wait()
            return "TESTPHONE02"
        })
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")

        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("probe start") { await probeGate.arrivalCount() == 1 }
        fixture.binder.retire(session: fixture.session)
        await probeGate.releaseAll()
        await drainTasks()

        #expect(fixture.launcher.launches.isEmpty)
    }

    @Test
    func terminalShutdownRejectsQueuedTopologyAfterCleanupSuspends() async throws {
        let probeGate = BindingAsyncGate()
        let cleanupGate = BindingAsyncGate()
        let fixture = try makeFixture(probe: { _ in
            await probeGate.wait()
            return "TESTPHONE02"
        })
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")

        let initialTasks = fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("probe start") { await probeGate.arrivalCount() == 1 }
        fixture.binder.shutdown()
        let suspendedCleanup = Task { await cleanupGate.wait() }
        try await waitUntil("termination cleanup suspension") { await cleanupGate.arrivalCount() == 1 }

        let delayedPollTasks = fixture.binder.reconcile([candidate], in: fixture.session)
        await probeGate.releaseAll()
        for task in initialTasks + delayedPollTasks { await task.value }

        #expect(fixture.launcher.launches.isEmpty)
        await cleanupGate.releaseAll()
        await suspendedCleanup.value
    }

    @Test
    func probeReturningAtDeadlineExpiresBeforeLaunchAdmission() async throws {
        let probeGate = BindingAsyncGate()
        let fixture = try makeFixture(probe: { _ in
            await probeGate.wait()
            return "TESTPHONE02"
        })
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")

        let delayedTasks = fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("probe start") { await probeGate.arrivalCount() == 1 }
        fixture.clock.advance(10)
        await probeGate.releaseAll()
        for task in delayedTasks { await task.value }

        #expect(fixture.launcher.launches.isEmpty)
        #expect(fixture.binder.reconcile([candidate], in: fixture.session).isEmpty)
        fixture.clock.advance(5)
        let retryTasks = fixture.binder.reconcile([candidate], in: fixture.session)
        for task in retryTasks { await task.value }
        #expect(fixture.launcher.launches.count == 1)
        #expect(fixture.launcher.launches.first?.nonce == Data(repeating: 2, count: 32))
    }

    @Test
    func cancellationDuringLaunchRejectsLateCompletionAndResponse() async throws {
        let launchGate = BindingAsyncGate()
        let fixture = try makeFixture(launch: { serial, url, recorder in
            recorder.append(serial: serial, url: url)
            await launchGate.wait()
        })
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")

        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("launch start") { await launchGate.arrivalCount() == 1 }
        let launch = try #require(fixture.launcher.launches.first)
        fixture.binder.retire(session: fixture.session)
        let replacement = ADBBindingSession(companionID: fixture.session.companionID, generation: 8)
        fixture.binder.reconcile([candidate], in: replacement)
        fixture.binder.reconcile([candidate], in: replacement)
        await drainTasks()
        #expect(fixture.launcher.launches.count == 1)

        await launchGate.releaseAll()
        await drainTasks()
        #expect(try await fixture.binder.accept(fixture.response(for: launch), from: fixture.peer, in: fixture.session) == nil)
        #expect(try fixture.store.record(for: candidate.serial) == nil)

        fixture.binder.reconcile([candidate], in: replacement)
        try await waitUntil("replacement launch after old process finishes") {
            fixture.launcher.launches.count == 2
        }
        fixture.binder.retire(session: replacement)
        await launchGate.releaseAll()
    }

    @Test
    func persistenceFailureDoesNotValidateAndAllowsBoundedRetry() async throws {
        let fixture = try makeFixture()
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("initial launch") { fixture.launcher.launches.count == 1 }
        fixture.backend.failWrites = true
        await #expect(throws: BindingTestError.self) {
            try await fixture.binder.accept(
                fixture.response(for: try #require(fixture.launcher.launches.first)),
                from: fixture.peer,
                in: fixture.session
            )
        }

        fixture.backend.failWrites = false
        fixture.clock.advance(5)
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("retry after persistence failure") { fixture.launcher.launches.count == 2 }
        _ = try await fixture.binder.accept(
            fixture.response(for: try #require(fixture.launcher.launches.last)),
            from: fixture.peer,
            in: fixture.session
        )
        #expect(try fixture.store.record(for: candidate.serial)?.deviceID == fixture.peer.deviceID)
    }

    @Test
    func persistedAliasStillNeedsFreshProofAndUnrelatedNameDoesNotLaunch() async throws {
        let fixture = try makeFixture()
        let persisted = "192.168.42.40:39643"
        try fixture.store.save(
            .init(
                adbSerial: persisted,
                deviceID: fixture.peer.deviceID,
                identityPublicKeySHA256: Data(SHA256.hash(data: fixture.peer.identityPublicKey)),
                verifiedAt: Date(timeIntervalSince1970: 10),
                hardwareSerial: "TESTPHONE02"
            )
        )
        let candidates = [
            ADBBindingCandidate(
                serial: persisted,
                peer: fixture.peer,
                hostID: "test-host",
                nameMatches: false,
                revalidate: true
            ),
            ADBBindingCandidate(
                serial: "unrelated:1234",
                peer: fixture.peer,
                hostID: "test-host",
                nameMatches: false,
                revalidate: true
            ),
        ]

        fixture.binder.reconcile(candidates, in: fixture.session)
        try await waitUntil("persisted alias launch") { fixture.launcher.launches.count == 1 }

        #expect(fixture.launcher.launches.map(\.serial) == [persisted])
    }

    @Test
    func retirementWhilePersistenceIsInFlightCannotValidateOldSession() async throws {
        let fixture = try makeFixture()
        let candidate = fixture.candidate(serial: "192.168.42.40:39643")
        fixture.binder.reconcile([candidate], in: fixture.session)
        try await waitUntil("initial launch") { fixture.launcher.launches.count == 1 }
        let response = try fixture.response(for: try #require(fixture.launcher.launches.first))
        fixture.backend.pauseWrites()

        let acceptance = Task { @MainActor in
            try await fixture.binder.accept(response, from: fixture.peer, in: fixture.session)
        }
        try await waitUntil("persistence start") { fixture.backend.writeIsWaiting }
        fixture.binder.retire(session: fixture.session)
        fixture.backend.releaseWrites()

        #expect(try await acceptance.value == nil)
    }

    private func makeFixture(
        probe: (@Sendable (String) async -> String?)? = nil,
        launch: (@Sendable (String, URL, BindingLaunchRecorder) async throws -> Void)? = nil
    ) throws -> BindingFixture {
        let clock = BindingTestClock()
        let nonceSource = BindingNonceSource()
        let launcher = BindingLaunchRecorder()
        let exhaustions = BindingExhaustionRecorder()
        let backend = BindingMemoryBackend()
        let store = ADBBindingStore(backend: backend, service: "test.binding.recovery")
        let identity = try makePeer(deviceID: "fold")
        let binder = ADBIdentityBinder(
            store: store,
            policy: policy,
            now: clock.now,
            makeNonce: nonceSource.next,
            hardwareSerialProbe: probe ?? { _ in "TESTPHONE02" },
            deepLinkLauncher: { serial, url in
                if let launch {
                    try await launch(serial, url, launcher)
                } else {
                    launcher.append(serial: serial, url: url)
                }
            },
            exhaustionHandler: exhaustions.append
        )
        return BindingFixture(
            binder: binder,
            store: store,
            backend: backend,
            clock: clock,
            launcher: launcher,
            exhaustions: exhaustions,
            privateKey: identity.privateKey,
            peer: identity.peer,
            session: .init(companionID: "fold.local", generation: 7)
        )
    }

    private func makePeer(deviceID: String) throws -> (privateKey: P256.Signing.PrivateKey, peer: PairedPeer) {
        var keyBytes = Data(repeating: 0, count: 32)
        keyBytes[31] = deviceID == "other" ? 2 : 1
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: keyBytes)
        return (
            privateKey,
            PairedPeer(
                deviceID: deviceID,
                displayName: "Galaxy Z Fold5",
                identityPublicKey: privateKey.publicKey.x963Representation,
                tlsCertificateSHA256: Data(repeating: 0x44, count: 32),
                pairedAt: Date(timeIntervalSince1970: 500)
            )
        )
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 200 {
            if await condition() { return }
            await Task.yield()
        }
        throw BindingTestError.timedOut(description)
    }

    private func drainTasks() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }
}

@MainActor
private struct BindingFixture {
    let binder: ADBIdentityBinder
    let store: ADBBindingStore
    let backend: BindingMemoryBackend
    let clock: BindingTestClock
    let launcher: BindingLaunchRecorder
    let exhaustions: BindingExhaustionRecorder
    let privateKey: P256.Signing.PrivateKey
    let peer: PairedPeer
    let session: ADBBindingSession

    func candidate(serial: String) -> ADBBindingCandidate {
        .init(serial: serial, peer: peer, hostID: "test-host", nameMatches: true, revalidate: true)
    }

    func response(for launch: BindingLaunch) throws -> GBAdbBindingResponse {
        var response = GBAdbBindingResponse()
        response.adbSerial = launch.serial
        response.nonce = launch.nonce
        response.identityPublicKey = peer.identityPublicKey
        response.signature = try privateKey.signature(
            for: ADBBindingTranscript.make(
                hostID: "test-host",
                adbSerial: launch.serial,
                nonce: launch.nonce,
                androidPublicKey: peer.identityPublicKey
            )
        ).derRepresentation
        return response
    }
}
