import Foundation

/// SurfaceFlinger panel state, independent of PowerManager wakefulness and
/// virtual display state. This says nothing about Android keyguard.
public enum PhonePanelPowerState: Equatable, Sendable {
    case on, off, unknown
}

public enum PhonePanelPowerParser {
    public static func parse(_ output: String) -> PhonePanelPowerState {
        guard let snapshot = snapshot(output), case let .physical(panels) = snapshot else { return .unknown }
        if panels.allSatisfy({ !$0.on }) { return .off }
        if panels.allSatisfy(\.on) { return .on }
        return .unknown // Scalar callers cannot restore mixed physical panels.
    }
    public static func snapshot(_ output: String) -> PhonePanelPowerSnapshot? {
        guard output.utf8.count <= 8 * 1024 * 1024 else { return nil }
        struct Display { var physical = false; var mode: PhonePanelPowerState? }
        var displays: [String: Display] = [:]
        var currentID: String?
        var currentVirtual = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^(?:Virtual )?Display \d+\b"#, options: .regularExpression) != nil {
                currentVirtual = line.hasPrefix("Virtual ")
                let fields = line.split(whereSeparator: \.isWhitespace)
                let index = currentVirtual ? 2 : 1
                let id = String(fields[index].prefix(while: \.isNumber))
                currentID = id
                if displays[id] == nil { displays[id] = Display() }
                if !currentVirtual, line.contains("HWC display") { displays[id]?.physical = true }
            } else if line == "connectionType=Internal", !currentVirtual, let id = currentID {
                displays[id]?.physical = true
            } else if line.hasPrefix("powerMode="), !currentVirtual, let id = currentID {
                let value = line.dropFirst("powerMode=".count).trimmingCharacters(in: .whitespaces)
                displays[id]?.mode = value == "OFF" ? .off : value == "ON" ? .on : .unknown
            }
        }
        let physical = displays.filter { $0.value.physical }
        guard !physical.isEmpty, physical.values.allSatisfy({ $0.mode != nil && $0.mode != .unknown }) else { return nil }
        return try? PhonePanelPowerSnapshot(validating: physical.map { .init(id: $0.key, on: $0.value.mode == .on) })
    }
}

public struct PhonePhysicalPanelState: Codable, Equatable, Sendable {
    public let id: String
    public let on: Bool
    public init(id: String, on: Bool) { self.id = id; self.on = on }
}

/// Exact physical tokens come from SurfaceControl's physical ID inventory. A
/// remote shell owner may retain its snapshot privately and attest its summary.
public enum PhonePanelPowerSnapshot: Equatable, Sendable {
    case physical([PhonePhysicalPanelState])
    case remotelyOwned(hasActivePanel: Bool)

    public init(validating panels: [PhonePhysicalPanelState]) throws {
        guard !panels.isEmpty, panels.count <= 8, Set(panels.map(\.id)).count == panels.count,
              panels.allSatisfy({ panel in
                  guard !panel.id.isEmpty, panel.id.count <= 20, let numeric = UInt64(panel.id) else { return false }
                  return String(numeric) == panel.id
              })
        else { throw SnapshotError.invalidPhysicalInventory }
        self = .physical(panels.sorted { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count })
    }
    public var isValid: Bool {
        switch self { case let .physical(panels): (try? Self(validating: panels)) != nil; case .remotelyOwned: true }
    }
    public var hasActivePanel: Bool {
        switch self { case let .physical(panels): panels.contains(where: \.on); case let .remotelyOwned(active): active }
    }
    public var isAllOff: Bool { !hasActivePanel }
    public func settingAllOff() throws -> Self {
        switch self {
        case let .physical(panels): try Self(validating: panels.map { .init(id: $0.id, on: false) })
        case .remotelyOwned: .remotelyOwned(hasActivePanel: false)
        }
    }
    public var physicalIDs: Set<String>? {
        if case let .physical(panels) = self { return Set(panels.map(\.id)) }; return nil
    }
    public enum SnapshotError: Error { case invalidPhysicalInventory, unknownPhysicalState }
}

/// Video may arrive before the producer's control socket. Physical privacy is
/// acquired only once both current-attempt signals have arrived.
public struct PhonePrivacySessionReadiness: Sendable {
    public enum Event: Sendable { case firstFrame, controlReady }
    private var firstFrame = false
    private var controlReady = false
    public private(set) var isReady = false
    public init() {}
    public mutating func reset() { self = Self() }
    @discardableResult public mutating func receive(_ event: Event) -> Bool {
        switch event { case .firstFrame: firstFrame = true; case .controlReady: controlReady = true }
        guard !isReady, firstFrame && controlReady else { return false }
        isReady = true; return true
    }
}
