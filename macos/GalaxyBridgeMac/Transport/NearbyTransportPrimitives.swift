import Foundation

/// A peripheral UUID is an in-memory routing hint, never a paired identity.
struct NearbyDiscoverySuggestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let model: String?
}

enum NearbyDiscoveryMetadata {
    struct Payload { let model: String; let pairedHostFingerprint: Data? }
    static func decode(_ data: Data) -> String? { parse(data)?.model }
    static func parse(_ data: Data) -> Payload? {
        guard data.count <= 134, let value = String(data: data, encoding: .utf8) else { return nil }
        let fields = value.split(separator: "\n", omittingEmptySubsequences: false)
        guard (fields.count == 2 && fields[0] == "GBD1") || (fields.count == 3 && fields[0] == "GBD2") else { return nil }
        let bytes = fields[1].utf8
        guard (1...64).contains(bytes.count) else { return nil }
        guard bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [32, 40, 41, 43, 45, 46, 95].contains($0) }),
              let model = String(bytes: bytes, encoding: .utf8), model == model.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        var fingerprint: Data?
        if fields.count == 3 {
            let hex = Array(fields[2].utf8)
            guard hex.count == 64, hex.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
            fingerprint = Data(stride(from: 0, to: 64, by: 2).map { nibble(hex[$0]) * 16 + nibble(hex[$0 + 1]) })
        }
        return Payload(model: model, pairedHostFingerprint: fingerprint)
    }
}

/// Memory-only, bounded independently of trust storage and network sessions.
struct NearbyDiscoveryCatalog {
    private struct Entry {
        var seen: TimeInterval
        var model: String?
        var probed: TimeInterval?
        var trusted = false
        var hostHintMatches = false
    }
    private var entries: [UUID: Entry] = [:]
    private var activeProbe: UUID?
    private var nextProbeTime: TimeInterval = 0
    var identifiers: Set<UUID> { Set(entries.keys) }
    var suggestions: [NearbyDiscoverySuggestion] {
        entries.filter { !$0.value.trusted && !$0.value.hostHintMatches }.sorted { $0.key.uuidString < $1.key.uuidString }.prefix(8)
            .map { NearbyDiscoverySuggestion(id: $0.key, model: $0.value.model) }
    }
    mutating func observe(_ id: UUID, at now: TimeInterval) {
        expire(at: now)
        if var entry = entries[id] { entry.seen = now; entries[id] = entry; return }
        if entries.count >= 16, let oldest = entries.filter({ $0.key != activeProbe }).min(by: { $0.value.seen < $1.value.seen })?.key {
            entries.removeValue(forKey: oldest)
        }
        guard entries.count < 16 else { return }
        entries[id] = Entry(seen: now)
    }
    mutating func expire(at now: TimeInterval) { entries = entries.filter { now - $0.value.seen < 30 } }
    mutating func markTrusted(_ id: UUID) { entries[id]?.trusted = true }
    mutating func nextProbe(at now: TimeInterval) -> UUID? {
        guard activeProbe == nil, now >= nextProbeTime,
              let id = entries.filter({ !$0.value.trusted && ($0.value.probed == nil || now - $0.value.probed! >= 30) })
                .sorted(by: { $0.key.uuidString < $1.key.uuidString }).first?.key else { return nil }
        entries[id]?.probed = now; activeProbe = id; nextProbeTime = now + 2
        return id
    }
    mutating func finishProbe(_ id: UUID, metadata: Data?, localHostFingerprint: Data? = nil) {
        guard activeProbe == id else { return }
        activeProbe = nil
        if let metadata, let parsed = NearbyDiscoveryMetadata.parse(metadata) {
            entries[id]?.model = parsed.model
            // This unauthenticated hint can hide only its own suggestion. It
            // cannot grant trust, identity, connection, or a Wi-Fi operation.
            entries[id]?.hostHintMatches = localHostFingerprint != nil && parsed.pairedHostFingerprint == localHostFingerprint
        }
    }
    mutating func removeAll() { entries.removeAll(); activeProbe = nil; nextProbeTime = 0 }
}

struct NearbyPairingRetryBudget {
    private var attempts = 0
    private var nextAttempt: TimeInterval = 0
    mutating func permit(at now: TimeInterval) -> Bool {
        guard attempts < 24, now >= nextAttempt else { return false }
        attempts += 1; nextAttempt = now + 5
        return true
    }
}

enum NearbyTransportFailure: Error { case frame, invalidOffer, unavailable, authentication, timeout, association, ownership, descriptor }

/// Bluetooth bootstraps a separately verified Wi-Fi lease. Retirement remains
/// terminal even when an asynchronous verification finishes later.
struct NearbyLinkLifetime {
    private(set) var verified = false
    private(set) var retired = false
    private(set) var bootstrapDetached = false
    mutating func markVerified() -> Bool {
        guard !retired else { return false }
        verified = true; return true
    }
    var retiresOnBootstrapLoss: Bool { !verified }
    mutating func detachBootstrap() { bootstrapDetached = true }
    mutating func retire() { retired = true }
}

struct NearbyLeaseReceipt {
    let requestID: String
    let deviceID: String
    let sessionID: String
    var expectedState = "disabled"
    var expectedLeaseID = ""
    func accepts(requestID: String, deviceID: String, sessionID: String, state: String, error: String, leaseID: String = "") -> Bool {
        self.requestID == requestID && self.deviceID == deviceID && self.sessionID == sessionID &&
            state == expectedState && leaseID == expectedLeaseID && error.isEmpty
    }
}

/// Used only after AEAD, envelope identity and current trust validation.
enum NearbyDirectStatusReceipt {
    enum Outcome: Equatable { case ignore, process, failure(String) }
    static func classify(requestID: String, expectedRequestID: String, state: String, errorCode: String) -> Outcome {
        guard !expectedRequestID.isEmpty, requestID == expectedRequestID else { return .ignore }
        guard state == "failed", !errorCode.isEmpty else { return .process }
        let bytes = errorCode.utf8
        guard bytes.count <= 128, let first = bytes.first, (97...122).contains(first),
              bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            return .failure("nearby_request_failed")
        }
        return .failure(errorCode)
    }
}

struct NearbyLeaseRenewalState {
    private var lastConfirmed: ContinuousClock.Instant
    init(confirmedAt: ContinuousClock.Instant) { lastConfirmed = confirmedAt }
    mutating func confirmed(at time: ContinuousClock.Instant) { lastConfirmed = time }
    // Retire locally before Android's45s expiry; its clock also advances while
    // the Mac sleeps, so do not resurrect an overdue lease after wake.
    func expired(at time: ContinuousClock.Instant) -> Bool { time >= lastConfirmed + .seconds(35) }
}

struct NearbyTransportDecoder {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [Data] {
        guard buffer.count + bytes.count <= 65_540 else { throw NearbyTransportFailure.frame }
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard (1...65_536).contains(size), frames.count < 8 else { throw NearbyTransportFailure.frame }
            guard buffer.count >= Int(size) + 4 else { break }
            let start = buffer.index(buffer.startIndex, offsetBy: 4)
            frames.append(buffer.subdata(in: start..<buffer.index(start, offsetBy: Int(size))))
            buffer.removeFirst(Int(size) + 4)
        }
        return frames
    }
    static func encode(_ bytes: Data) throws -> Data {
        guard (1...65_536).contains(bytes.count) else { throw NearbyTransportFailure.frame }
        var size = UInt32(bytes.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + bytes
    }
}

struct NearbyOfflineOffer {
    let hostID: String
    let sessionID = UUID().uuidString.lowercased()
    let token = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    var context = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    var consentName: String?
    let identity: Data
    let expiresAt: Date
    init(hostID: String, identity: Data, now: Date = Date()) throws {
        guard UUID(uuidString: hostID) != nil, identity.count == 65 else { throw NearbyTransportFailure.invalidOffer }
        self.hostID = hostID; self.identity = identity
        expiresAt = now.addingTimeInterval(120)
    }
    func valid(at date: Date = Date()) -> Bool { date < expiresAt }
    var uri: String {
        func url64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        var components = URLComponents()
        components.scheme = "galaxybridge"; components.host = "pair"
        components.queryItems = [URLQueryItem(name: "transport", value: "nearby"), .init(name: "version", value: "1"),
            .init(name: "host", value: hostID), .init(name: "sid", value: sessionID),
            .init(name: "identity", value: url64(identity)), .init(name: "token", value: url64(token)),
            .init(name: "context", value: url64(context)), .init(name: "expires", value: String(Int64(expiresAt.timeIntervalSince1970)))]
        return components.string!
    }
}

struct NearbyAssociationOwnership {
    private(set) var network: String?
    private var owners = Set<UUID>()
    func permitsSharing(network: String, currentName: String?, currentBSSID: String?, ownedBSSID: String?) -> Bool {
        guard !owners.isEmpty, !network.isEmpty, self.network == network, currentName == network,
              let currentBSSID, let ownedBSSID, !ownedBSSID.isEmpty else { return false }
        return currentBSSID == ownedBSSID
    }
    mutating func acquire(owner: UUID, network: String) -> Bool {
        guard self.network == nil || self.network == network else { return false }
        self.network = network; owners.insert(owner); return true
    }
    mutating func release(owner: UUID) -> Bool {
        guard owners.remove(owner) != nil, owners.isEmpty else { return false }
        network = nil; return true
    }
}

enum NearbyAssociationRestoration {
    static func permits(currentName: String?, currentBSSID: String?, ownedName: String,
                        ownedBSSID: String?, positivelyUnassociated: Bool) -> Bool {
        (currentName == ownedName && currentBSSID == ownedBSSID) ||
            (currentName == nil && currentBSSID == nil && positivelyUnassociated)
    }
}
