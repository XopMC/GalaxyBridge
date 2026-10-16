import Foundation

public struct InternetPeerKey: Hashable, Codable, Sendable {
    public let deviceID: String
    public let generation: UInt64
    public init(deviceID: String, generation: UInt64) { self.deviceID = deviceID; self.generation = generation }
}

public enum InternetUpstream: String, Codable, Sendable { case wifi, cellular, unavailable }
public struct InternetGateway: Equatable, Sendable {
    public let peer: InternetPeerKey
    public let leaseID: String
    public var upstream: InternetUpstream
    public var healthy: Bool
    public init(peer: InternetPeerKey, leaseID: String, upstream: InternetUpstream, healthy: Bool) {
        self.peer = peer; self.leaseID = leaseID; self.upstream = upstream; self.healthy = healthy
    }
}
public enum InternetGatewayPolicy: Equatable, Sendable { case automatic, balanced, fixed(InternetPeerKey) }

/// Coordinator-confined pool. Selection leases pin a flow until explicit close
/// or withdrawal; changing policy never silently changes an existing flow's IP.
public struct InternetGatewayPool: Sendable {
    public enum Failure: Error { case invalidGateway, capacity }
    public private(set) var gateways: [InternetPeerKey: InternetGateway] = [:]
    private var flows: [String: InternetGateway] = [:]
    private var cursor: UInt64 = 0
    private let capacity: Int
    private let flowCapacity: Int
    public init(capacity: Int = 8, flowCapacity: Int = 4096) {
        self.capacity = min(max(1, capacity), 8); self.flowCapacity = min(max(1, flowCapacity), 16384)
    }
    @discardableResult public mutating func update(_ gateway: InternetGateway) throws -> Set<String> {
        guard !gateway.peer.deviceID.isEmpty, gateway.peer.deviceID.utf8.count <= 256,
              gateway.peer.generation > 0, !gateway.leaseID.isEmpty, gateway.leaseID.utf8.count <= 256,
              !(gateway.healthy && gateway.upstream == .unavailable) else { throw Failure.invalidGateway }
        guard gateways[gateway.peer] != nil || gateways.count < capacity else { throw Failure.capacity }
        var affected: Set<String> = []
        if let old = gateways[gateway.peer], old.leaseID != gateway.leaseID || !gateway.healthy {
            affected = remove(peer: old.peer, leaseID: old.leaseID)
        }
        gateways[gateway.peer] = gateway
        return affected
    }
    public mutating func select(flowID: String, policy: InternetGatewayPolicy) -> InternetGateway? {
        guard !flowID.isEmpty, flowID.utf8.count <= 256 else { return nil }
        if let pinned = flows[flowID] { return pinned }
        guard flows.count < flowCapacity else { return nil }
        let available = gateways.values.filter(\.healthy).sorted {
            if $0.peer.deviceID != $1.peer.deviceID { return $0.peer.deviceID < $1.peer.deviceID }
            return $0.peer.generation < $1.peer.generation
        }
        let chosen: InternetGateway?
        switch policy {
        case .automatic: chosen = available.first(where: { $0.upstream == .wifi }) ?? available.first
        case .balanced:
            chosen = available.isEmpty ? nil : available[Int(cursor % UInt64(available.count))]
            if chosen != nil { cursor &+= 1 }
        case let .fixed(peer): chosen = available.first(where: { $0.peer == peer })
        }
        if let chosen { flows[flowID] = chosen }
        return chosen
    }
    public mutating func close(flowID: String) { flows.removeValue(forKey: flowID) }
    @discardableResult public mutating func remove(peer: InternetPeerKey, leaseID: String) -> Set<String> {
        guard gateways[peer]?.leaseID == leaseID else { return [] }
        gateways.removeValue(forKey: peer)
        let affected = Set(flows.compactMap { $0.value.peer == peer && $0.value.leaseID == leaseID ? $0.key : nil })
        for key in affected { flows.removeValue(forKey: key) }
        return affected
    }
}

public enum DirectConnectivityPolicy {
    public enum Concurrency: String, Codable, Sendable { case unknown, verified, unsupported }
    public enum Route: String, Codable, Sendable { case usb, lan, direct }
    public static func canCreateNetwork(hasUpstreamWiFi: Bool, concurrency: Concurrency) -> Bool {
        !hasUpstreamWiFi || concurrency == .verified
    }
    public static func route(existingHealthy: Route?, usb: Bool, lan: Bool, direct: Bool) -> Route? {
        if let existingHealthy { return existingHealthy }
        return usb ? .usb : lan ? .lan : direct ? .direct : nil
    }
}

public struct DirectGroupOwnership: Sendable {
    public private(set) var owner: InternetPeerKey?
    public private(set) var leaseID: UUID?
    public init() {}
    public mutating func acquire(owner: InternetPeerKey, leaseID: UUID) -> Bool {
        guard self.owner == nil || (self.owner == owner && self.leaseID == leaseID) else { return false }
        self.owner = owner; self.leaseID = leaseID; return true
    }
    public mutating func release(owner: InternetPeerKey, leaseID: UUID) -> Bool {
        guard self.owner == owner, self.leaseID == leaseID else { return false }
        self.owner = nil; self.leaseID = nil; return true
    }
}
