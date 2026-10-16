import Foundation

struct NearbyGroupMember {
    let generation: UUID
    let deviceID: String?
    let target: String?
    let ownerDeviceID: String?
    let anchor: Bool
}

enum NearbyGroupOwnership {
    static func revokedSessions(deviceID: String, members: [NearbyGroupMember]) -> [UUID] {
        members.filter { $0.deviceID == deviceID || $0.target == deviceID || $0.ownerDeviceID == deviceID }
            .sorted { left, right in
                let leftOwner = left.deviceID == deviceID || left.target == deviceID
                let rightOwner = right.deviceID == deviceID || right.target == deviceID
                if leftOwner != rightOwner { return !leftOwner }
                return left.generation.uuidString < right.generation.uuidString
            }.map(\.generation)
    }
    static func retainsAnchor(_ member: NearbyGroupMember, disconnecting deviceID: String, members: [NearbyGroupMember]) -> Bool {
        member.deviceID == deviceID && member.ownerDeviceID == deviceID &&
            members.contains { $0.generation != member.generation && !$0.anchor && $0.ownerDeviceID == deviceID }
    }
    static func trusted(identity: Data, pin: Data, currentIdentity: Data?, currentPin: Data?) -> Bool {
        currentIdentity == identity && currentPin == pin
    }
}
