#if !GALAXYBRIDGE_APP_STORE
import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeProtocol
import Security

enum ADBIdentityBindingError: Error, LocalizedError {
    case invalidResponse
    case expired
    case signatureRejected

    var errorDescription: String? { String(localized: "ERROR_PAIRING_IDENTITY") }
}

@MainActor
final class ADBIdentityBinder {
    private struct BindingKey: Hashable {
        let serial: String
        let peerID: String
    }

    private struct PendingBinding {
        let adbSerial: String
        let nonce: Data
        let hostID: String
        let peer: PairedPeer
        let createdAt: Date
        let deadline: Date
        let session: ADBBindingSession
        var hardwareSerial: String?
        var isAccepting: Bool
    }

    private final class StoreBox: @unchecked Sendable {
        let value: ADBBindingStore

        init(_ value: ADBBindingStore) {
            self.value = value
        }
    }

    private struct RecoveryEntry {
        let session: ADBBindingSession
        var attemptsStarted: Int
        var nextEligibleAt: Date
        var pending: PendingBinding?
        var launchTask: Task<Void, Never>?
        var exhaustedReported: Bool
        var validated: Bool
    }

    private let store: StoreBox
    private let policy: ADBBindingRecoveryPolicy
    private let now: @Sendable () -> Date
    private let makeNonce: @Sendable () throws -> Data
    private let hardwareSerialProbe: @Sendable (String) async -> String?
    private let deepLinkLauncher: @Sendable (String, URL) async throws -> Void
    private let exhaustionHandler: @Sendable (ADBBindingRecoveryExhaustion) -> Void
    private var entries: [BindingKey: RecoveryEntry] = [:]
    private var pendingByNonce: [Data: BindingKey] = [:]
    // Cancellation cannot prove a launched ADB subprocess has stopped. Keep
    // the alias lease until the injected launcher itself returns.
    private var activeLaunches = Set<BindingKey>()
    private var isShutDown = false

    init(
        store: ADBBindingStore = ADBBindingStore(),
        policy: ADBBindingRecoveryPolicy = .production,
        now: @escaping @Sendable () -> Date = Date.init,
        makeNonce: @escaping @Sendable () throws -> Data = { try secureRandomBytes(count: 32) },
        hardwareSerialProbe: @escaping @Sendable (String) async -> String? = { serial in
            await Task.detached(priority: .utility) {
                try? ADBClient().hardwareSerial(serial: serial)
            }.value
        },
        deepLinkLauncher: @escaping @Sendable (String, URL) async throws -> Void = { serial, url in
            try await Task.detached(priority: .utility) {
                try ADBClient().openDeepLink(serial: serial, url: url)
            }.value
        },
        exhaustionHandler: @escaping @Sendable (ADBBindingRecoveryExhaustion) -> Void = { _ in }
    ) {
        self.store = StoreBox(store)
        self.policy = policy
        self.now = now
        self.makeNonce = makeNonce
        self.hardwareSerialProbe = hardwareSerialProbe
        self.deepLinkLauncher = deepLinkLauncher
        self.exhaustionHandler = exhaustionHandler
    }

    @discardableResult
    func reconcile(
        _ candidates: [ADBBindingCandidate],
        in session: ADBBindingSession
    ) -> [Task<Void, Never>] {
        guard !isShutDown else { return [] }
        let instant = now()
        let desired = Set(candidates.map { BindingKey(serial: $0.serial, peerID: $0.peer.deviceID) })
        var scheduledTasks: [Task<Void, Never>] = []

        for key in Array(entries.keys) where entries[key]?.session.companionID == session.companionID {
            guard entries[key]?.session == session, desired.contains(key) else {
                retire(key: key)
                continue
            }
        }

        for candidate in candidates {
            let key = BindingKey(serial: candidate.serial, peerID: candidate.peer.deviceID)
            guard valid(candidate) else {
                retire(key: key)
                continue
            }
            if let existing = entries[key], existing.session != session {
                retire(key: key)
            }
            if entries[key] == nil {
                entries[key] = RecoveryEntry(
                    session: session,
                    attemptsStarted: 0,
                    nextEligibleAt: instant,
                    pending: nil,
                    launchTask: nil,
                    exhaustedReported: false,
                    validated: false
                )
            }
            advanceExpiredAttempt(for: key, at: instant)
            if let task = startPreparationIfEligible(for: key, candidate: candidate, at: instant) {
                scheduledTasks.append(task)
            }
        }
        return scheduledTasks
    }

    func retryExhausted(in session: ADBBindingSession) {
        let instant = now()
        for key in Array(entries.keys) where entries[key]?.session == session {
            guard var entry = entries[key], entry.pending == nil,
                  entry.attemptsStarted >= policy.attemptLimit, !entry.validated
            else { continue }
            entry.attemptsStarted = 0
            entry.nextEligibleAt = instant
            entry.exhaustedReported = false
            entries[key] = entry
        }
    }

    func retryAllExhausted() {
        let instant = now()
        for key in Array(entries.keys) {
            guard var entry = entries[key], entry.pending == nil,
                  entry.attemptsStarted >= policy.attemptLimit, !entry.validated
            else { continue }
            entry.attemptsStarted = 0
            entry.nextEligibleAt = instant
            entry.exhaustedReported = false
            entries[key] = entry
        }
    }

    func retire(session: ADBBindingSession) {
        for key in Array(entries.keys) where entries[key]?.session == session {
            retire(key: key)
        }
    }

    func retire(peerID: String) {
        for key in Array(entries.keys) where key.peerID == peerID {
            retire(key: key)
        }
    }

    func shutdown() {
        isShutDown = true
        for key in Array(entries.keys) { retire(key: key) }
    }

    private func valid(_ candidate: ADBBindingCandidate) -> Bool {
        !candidate.serial.isEmpty && candidate.serial.count <= 128 && !candidate.hostID.isEmpty
    }

    private func advanceExpiredAttempt(for key: BindingKey, at instant: Date) {
        guard let pending = entries[key]?.pending, instant >= pending.deadline else { return }
        failAttempt(for: key, nonce: pending.nonce, at: instant)
    }

    private func startPreparationIfEligible(
        for key: BindingKey,
        candidate: ADBBindingCandidate,
        at instant: Date
    ) -> Task<Void, Never>? {
        guard var entry = entries[key], !entry.validated, entry.pending == nil,
              entry.launchTask == nil,
              !activeLaunches.contains(key),
              instant >= entry.nextEligibleAt
        else { return nil }
        guard entry.attemptsStarted < policy.attemptLimit else {
            reportExhaustionIfNeeded(for: key)
            return nil
        }

        let store = store
        let probe = hardwareSerialProbe
        let launcher = deepLinkLauncher
        let serial = candidate.serial
        let task = Task { [weak self] in
            let persistentlyVerified = await Task.detached(priority: .utility) {
                store.value.isVerified(serial: serial, peer: candidate.peer)
            }.value
            guard !Task.isCancelled, let self,
                  let challenge = self.prepareChallenge(
                      for: key,
                      candidate: candidate,
                      persistentlyVerified: persistentlyVerified
                  )
            else { return }
            let hardwareSerial = await probe(serial)
            guard !Task.isCancelled else { return }
            await self.continueLaunch(
                for: key,
                nonce: challenge.nonce,
                hardwareSerial: hardwareSerial,
                url: challenge.url,
                launcher: launcher
            )
        }
        entry.launchTask = task
        entries[key] = entry
        return task
    }

    private func prepareChallenge(
        for key: BindingKey,
        candidate: ADBBindingCandidate,
        persistentlyVerified: Bool
    ) -> (nonce: Data, url: URL)? {
        guard var entry = entries[key], entry.launchTask != nil, entry.pending == nil else { return nil }
        guard candidate.nameMatches || persistentlyVerified else {
            retire(key: key)
            return nil
        }
        guard candidate.revalidate || !persistentlyVerified else {
            retire(key: key)
            return nil
        }

        let nonce: Data
        do {
            nonce = try makeNonce()
        } catch {
            entry.attemptsStarted = policy.attemptLimit
            entry.launchTask = nil
            entries[key] = entry
            reportExhaustionIfNeeded(for: key)
            return nil
        }
        guard nonce.count == 32, let url = bindingURL(candidate: candidate, nonce: nonce) else {
            entry.attemptsStarted = policy.attemptLimit
            entry.launchTask = nil
            entries[key] = entry
            reportExhaustionIfNeeded(for: key)
            return nil
        }

        let instant = now()
        entry.attemptsStarted += 1
        entry.pending = PendingBinding(
            adbSerial: candidate.serial,
            nonce: nonce,
            hostID: candidate.hostID,
            peer: candidate.peer,
            createdAt: instant,
            deadline: instant.addingTimeInterval(policy.requestTimeout),
            session: entry.session,
            hardwareSerial: nil,
            isAccepting: false
        )
        pendingByNonce[nonce] = key
        entries[key] = entry
        return (nonce, url)
    }

    private func continueLaunch(
        for key: BindingKey,
        nonce: Data,
        hardwareSerial: String?,
        url: URL,
        launcher: @Sendable (String, URL) async throws -> Void
    ) async {
        guard var entry = entries[key], entry.pending?.nonce == nonce,
              !Task.isCancelled, !activeLaunches.contains(key)
        else { return }
        let instant = now()
        guard let deadline = entry.pending?.deadline, instant < deadline else {
            failAttempt(for: key, nonce: nonce, at: instant)
            return
        }
        entry.pending?.hardwareSerial = hardwareSerial
        entries[key] = entry
        activeLaunches.insert(key)
        defer { activeLaunches.remove(key) }
        do {
            try await launcher(key.serial, url)
            guard var current = entries[key], current.pending?.nonce == nonce else { return }
            current.launchTask = nil
            entries[key] = current
        } catch {
            failAttempt(for: key, nonce: nonce, at: now())
        }
    }

    private func bindingURL(candidate: ADBBindingCandidate, nonce: Data) -> URL? {
        var components = URLComponents()
        components.scheme = "galaxybridge"
        components.host = "bind"
        components.queryItems = [
            URLQueryItem(name: "host", value: candidate.hostID),
            URLQueryItem(name: "device", value: candidate.peer.deviceID),
            URLQueryItem(name: "serial", value: candidate.serial),
            URLQueryItem(name: "nonce", value: nonce.base64URLEncodedString()),
        ]
        return components.url
    }

    @discardableResult
    func accept(
        _ response: GBAdbBindingResponse,
        from peer: PairedPeer,
        in session: ADBBindingSession
    ) async throws -> ADBBindingRecord? {
        guard let key = pendingByNonce[response.nonce],
              var request = entries[key]?.pending,
              request.adbSerial == response.adbSerial,
              request.peer.deviceID == peer.deviceID,
              request.peer.identityPublicKey.constantTimeEquals(peer.identityPublicKey),
              !request.isAccepting,
              request.session == session
        else { return nil }

        let instant = now()
        guard instant < request.deadline else {
            failAttempt(for: key, nonce: response.nonce, at: instant)
            throw ADBIdentityBindingError.expired
        }
        guard response.nonce.count == 32,
              response.identityPublicKey.count == 65,
              response.nonce.constantTimeEquals(request.nonce),
              response.identityPublicKey.constantTimeEquals(peer.identityPublicKey)
        else {
            failAttempt(for: key, nonce: response.nonce, at: instant)
            throw ADBIdentityBindingError.invalidResponse
        }
        request.isAccepting = true
        if var entry = entries[key], entry.pending?.nonce == response.nonce {
            entry.pending = request
            entries[key] = entry
        } else {
            return nil
        }
        do {
            guard try ADBBindingTranscript.verify(
                signatureDER: response.signature,
                hostID: request.hostID,
                adbSerial: response.adbSerial,
                nonce: response.nonce,
                androidPublicKey: response.identityPublicKey
            ) else {
                failAttempt(for: key, nonce: response.nonce, at: instant)
                throw ADBIdentityBindingError.signatureRejected
            }
        } catch {
            failAttempt(for: key, nonce: response.nonce, at: instant)
            throw error
        }

        let record = ADBBindingRecord(
            adbSerial: response.adbSerial,
            deviceID: peer.deviceID,
            identityPublicKeySHA256: Data(SHA256.hash(data: peer.identityPublicKey)),
            verifiedAt: instant,
            hardwareSerial: request.hardwareSerial
        )
        do {
            let store = store
            try await Task.detached(priority: .utility) {
                try store.value.save(record)
            }.value
        } catch {
            guard entries[key]?.pending?.nonce == response.nonce else { return nil }
            failAttempt(for: key, nonce: response.nonce, at: instant)
            throw error
        }
        guard let current = entries[key],
              current.session == session,
              current.pending?.nonce == response.nonce,
              current.pending?.isAccepting == true
        else { return nil }
        pendingByNonce.removeValue(forKey: response.nonce)
        if var entry = entries[key] {
            entry.pending = nil
            entry.launchTask?.cancel()
            entry.launchTask = nil
            entry.validated = true
            entries[key] = entry
        }
        return record
    }

    private func failAttempt(for key: BindingKey, nonce: Data, at instant: Date) {
        guard var entry = entries[key], entry.pending?.nonce == nonce else { return }
        pendingByNonce.removeValue(forKey: nonce)
        entry.launchTask?.cancel()
        entry.launchTask = nil
        entry.pending = nil
        if entry.attemptsStarted >= policy.attemptLimit {
            entries[key] = entry
            reportExhaustionIfNeeded(for: key)
        } else {
            entry.nextEligibleAt = instant.addingTimeInterval(
                policy.backoff(afterAttempt: entry.attemptsStarted)
            )
            entries[key] = entry
        }
    }

    private func reportExhaustionIfNeeded(for key: BindingKey) {
        guard var entry = entries[key], !entry.exhaustedReported else { return }
        entry.exhaustedReported = true
        entries[key] = entry
        exhaustionHandler(.init(serial: key.serial, peerID: key.peerID, attempts: entry.attemptsStarted))
    }

    private func retire(key: BindingKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.launchTask?.cancel()
        if let nonce = entry.pending?.nonce { pendingByNonce.removeValue(forKey: nonce) }
    }
}

private func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw IdentityStoreError.keychain(status) }
        return data
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(UInt8(0)) { result, pair in result | (pair.0 ^ pair.1) } == 0
    }
}
#endif
