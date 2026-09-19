import Foundation

private actor SetupPeer: WirelessSetupClient {
    var services: [WirelessADBService]
    var connected = false
    var rejected = false
    var holdPair = false
    var pairing: CheckedContinuation<Void, Never>?
    var pairCalls = 0
    var connectCalls = 0
    init(_ services: [WirelessADBService]) { self.services = services }
    func discover() async throws -> [WirelessADBService] { services }
    func pair(_ service: WirelessADBService, code: WirelessADBPairingCode) async throws {
        pairCalls += 1
        if holdPair { await withCheckedContinuation { pairing = $0 } }
        if rejected { throw WirelessADBSetupError.pairingRejected }
    }
    func connect(_ service: WirelessADBService) async throws -> Bool { connectCalls += 1; return connected }
    func allowConnection() { connected = true }
    func rejectPair() { rejected = true }
    func delayPair() { holdPair = true }
    func releasePair() { pairing?.resume(); pairing = nil }
}

@main
@MainActor
enum WirelessSetupCoordinatorSpec {
    static func main() async throws {
        let services = WirelessADBService.parse("""
        adb-s24 _adb-tls-pairing._tcp 192.168.42.126:30001
        adb-s24 _adb-tls-connect._tcp 192.168.42.126:40009
        """)
        let peer = SetupPeer(services)
        let coordinator = WirelessSetupCoordinator(client: peer, pollDelay: .milliseconds(5), connectionAttempts: 4)
        coordinator.search()
        try await wait { coordinator.phase == .enterCode }
        coordinator.submit(code: "123")
        let invalidCalls = await peer.pairCalls
        precondition(invalidCalls == 0)
        coordinator.submit(code: "123456")
        try await wait { coordinator.phase == .connecting }
        precondition(coordinator.phase != .connected("192.168.42.126:40009"), "Pairing is not functional connection verification")
        await peer.allowConnection()
        try await wait { coordinator.phase == .connected("192.168.42.126:40009") }

        let unavailable = SetupPeer(services)
        let bounded = WirelessSetupCoordinator(client: unavailable, pollDelay: .milliseconds(1), connectionAttempts: 2)
        bounded.search()
        try await wait { bounded.phase == .enterCode }
        let attemptsBeforePairing = await unavailable.connectCalls
        bounded.submit(code: "123456")
        try await wait { bounded.phase == .failed("WIFI_SETUP_CONNECT_RETRY") }
        let attempts = await unavailable.connectCalls
        precondition(attempts - attemptsBeforePairing == 2)

        let wrongCode = SetupPeer(services)
        await wrongCode.rejectPair()
        let rejected = WirelessSetupCoordinator(client: wrongCode, pollDelay: .milliseconds(1))
        rejected.search()
        try await wait { rejected.phase == .enterCode }
        rejected.submit(code: "123456")
        try await wait { rejected.phase == .failed("WIFI_SETUP_CODE_REJECTED") }

        let delayed = SetupPeer(services)
        await delayed.delayPair()
        let cancelled = WirelessSetupCoordinator(client: delayed, pollDelay: .milliseconds(1))
        cancelled.search()
        try await wait { cancelled.phase == .enterCode }
        let connectsBeforeDelayedPair = await delayed.connectCalls
        cancelled.submit(code: "123456")
        try await waitAsync { await delayed.pairing != nil }
        cancelled.cancel()
        await delayed.releasePair()
        try await Task.sleep(for: .milliseconds(20))
        let staleConnects = await delayed.connectCalls
        precondition(staleConnects == connectsBeforeDelayedPair, "Cancelled generation must not connect or publish stale success")

        let many = SetupPeer(services + [.init(name: "adb-fold", kind: .pairing, endpoint: "192.168.42.40:30002")])
        let ambiguous = WirelessSetupCoordinator(client: many, pollDelay: .milliseconds(1))
        ambiguous.search()
        try await wait { ambiguous.phase == .multiplePhones }
        precondition(ambiguous.service == nil, "Do not choose a random phone")
        ambiguous.cancel()
        let trustedPeer = SetupPeer([services[1]])
        await trustedPeer.allowConnection()
        let trusted = WirelessSetupCoordinator(client: trustedPeer, pollDelay: .milliseconds(1))
        trusted.search()
        try await wait { trusted.phase == .connected("192.168.42.126:40009") }
        coordinator.cancel(); bounded.cancel(); rejected.cancel(); trusted.cancel()
        print("Wireless setup coordinator: invalid input, verified connection, bounded retries, rejected code, cancellation and multiple-phone checks passed")
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Expected state not reached")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private static func waitAsync(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
