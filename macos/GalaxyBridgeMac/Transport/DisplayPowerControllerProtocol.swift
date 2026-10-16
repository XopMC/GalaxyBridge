#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore

struct DisplayPowerControllerIdentity: Equatable, Sendable {
    let pid: Int32
    let startTime: String
}
struct DisplayPowerControllerAcknowledgement: Sendable {
    let identity: DisplayPowerControllerIdentity
    let initial: PhonePanelPowerSnapshot
    let current: PhonePanelPowerSnapshot
    private struct Wire: Decodable {
        let version: Int
        let pid: Int32
        let startTime: String
        let initial: [PhonePhysicalPanelState]
        let current: [PhonePhysicalPanelState]
        let ok: Bool
        let error: String
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw ProtocolError.invalidAcknowledgement }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == 1, wire.pid > 1, !wire.startTime.isEmpty,
              wire.startTime.count <= 20, let startTime = UInt64(wire.startTime), String(startTime) == wire.startTime,
              wire.error.utf8.count <= 128 else { throw ProtocolError.invalidAcknowledgement }
        if !wire.ok, !wire.error.isEmpty, wire.initial.isEmpty, wire.current.isEmpty {
            // The pinned child reports setup failures before accepting commands.
            // This is not panel evidence or a successful acknowledgement.
            throw StartupFailure(identity: .init(pid: wire.pid, startTime: wire.startTime), code: wire.error)
        }
        let initial = try PhonePanelPowerSnapshot(validating: wire.initial), current = try PhonePanelPowerSnapshot(validating: wire.current)
        guard initial.physicalIDs == current.physicalIDs else { throw ProtocolError.physicalInventoryChanged }
        let result = Self(identity: .init(pid: wire.pid, startTime: wire.startTime), initial: initial, current: current)
        if !wire.ok {
            guard !wire.error.isEmpty else { throw ProtocolError.invalidAcknowledgement }
            throw Rejection(acknowledgement: result, code: wire.error)
        }
        guard wire.error.isEmpty else { throw ProtocolError.invalidAcknowledgement }
        return result
    }
    func validating(identity: DisplayPowerControllerIdentity, initial: PhonePanelPowerSnapshot) throws -> Self {
        guard self.identity == identity, self.initial == initial else { throw ProtocolError.ownerChanged }; return self
    }
    struct StartupFailure: Error, Sendable { let identity: DisplayPowerControllerIdentity; let code: String }
    struct Rejection: Error, Sendable { let acknowledgement: DisplayPowerControllerAcknowledgement; let code: String }
    enum ProtocolError: Error { case invalidAcknowledgement, controllerRejected, physicalInventoryChanged, ownerChanged }
}
#endif
