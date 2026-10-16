import Foundation

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
    let context = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
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
