#if !GALAXYBRIDGE_APP_STORE
import Foundation

enum DisplayStateProtocolError: Error {
    case invalidAcknowledgement, identityChanged, initialSnapshotChanged, unexpectedReply
}

private enum DisplayStateWireRules {
    static func unsigned(_ text: String, maximum: UInt64 = .max) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(text), value <= maximum, String(value) == text else { return nil }
        return value
    }
    static func code(_ text: String, allowsEmpty: Bool = false) -> Bool {
        if text.isEmpty { return allowsEmpty }
        return text.utf8.count <= 96 && text.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    private struct Key: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        let intValue: Int? = nil
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: Decoder, expected: Set<String>) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == expected else { throw DisplayStateProtocolError.invalidAcknowledgement }
    }
}

/// Complete evidence, including raw panel modes and the scope of power stamps.
/// A Boolean panel projection cannot substitute for this restoration baseline.
struct DisplayStateSnapshot: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case off = "OFF", on = "ON", doze = "DOZE", dozeSuspend = "DOZE_SUSPEND", onSuspend = "ON_SUSPEND" }
    enum Wakefulness: String, Codable, Sendable {
        case asleep = "ASLEEP", awake = "AWAKE", dreaming = "DREAMING", dozing = "DOZING"
        var interactive: Bool { self == .awake || self == .dreaming }
        var aggregateRank: Int {
            switch self { case .asleep: 0; case .dozing: 1; case .dreaming: 2; case .awake: 3 }
        }
    }
    struct Panel: Codable, Equatable, Sendable {
        let id: String
        let mode: Mode
        private enum CodingKeys: String, CodingKey, CaseIterable { case id, mode }
        init(from decoder: Decoder) throws {
            try DisplayStateWireRules.keys(decoder, expected: Set(CodingKeys.allCases.map(\.rawValue)))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            mode = try values.decode(Mode.self, forKey: .mode)
            guard DisplayStateWireRules.unsigned(id) != nil else { throw DisplayStateProtocolError.invalidAcknowledgement }
        }
    }
    let panels: [Panel]
    let activeID: String
    let defaultInteractive: Bool
    let defaultWakefulness: Wakefulness
    let globalWakefulness: Wakefulness
    let transitionScope: String
    let lastGlobalWakeTime: UInt64
    let lastGlobalSleepTime: UInt64
    let defaultActivityTime: UInt64
    let defaultActivityNoChangeLightsTime: UInt64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case panels, activeID, defaultInteractive, defaultWakefulness, globalWakefulness, transitionScope
        case lastGlobalWakeTime, lastGlobalSleepTime, defaultActivityTime, defaultActivityNoChangeLightsTime
    }
    init(from decoder: Decoder) throws {
        try DisplayStateWireRules.keys(decoder, expected: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let incoming = try values.decode([Panel].self, forKey: .panels)
        activeID = try values.decode(String.self, forKey: .activeID)
        defaultInteractive = try values.decode(Bool.self, forKey: .defaultInteractive)
        defaultWakefulness = try values.decode(Wakefulness.self, forKey: .defaultWakefulness)
        globalWakefulness = try values.decode(Wakefulness.self, forKey: .globalWakefulness)
        transitionScope = try values.decode(String.self, forKey: .transitionScope)
        func time(_ key: CodingKeys) throws -> UInt64 {
            let text = try values.decode(String.self, forKey: key)
            guard let value = DisplayStateWireRules.unsigned(text, maximum: UInt64(Int64.max)) else {
                throw DisplayStateProtocolError.invalidAcknowledgement
            }
            return value
        }
        lastGlobalWakeTime = try time(.lastGlobalWakeTime)
        lastGlobalSleepTime = try time(.lastGlobalSleepTime)
        defaultActivityTime = try time(.defaultActivityTime)
        defaultActivityNoChangeLightsTime = try time(.defaultActivityNoChangeLightsTime)
        let selectedID = activeID
        guard (1...8).contains(incoming.count), Set(incoming.map(\.id)).count == incoming.count,
              incoming.contains(where: { $0.id == selectedID }), transitionScope == "GLOBAL",
              defaultInteractive == defaultWakefulness.interactive,
              (!defaultInteractive || globalWakefulness.interactive),
              defaultWakefulness.aggregateRank <= globalWakefulness.aggregateRank else {
            throw DisplayStateProtocolError.invalidAcknowledgement
        }
        panels = incoming.sorted { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(panels, forKey: .panels)
        try values.encode(activeID, forKey: .activeID)
        try values.encode(defaultInteractive, forKey: .defaultInteractive)
        try values.encode(defaultWakefulness, forKey: .defaultWakefulness)
        try values.encode(globalWakefulness, forKey: .globalWakefulness)
        try values.encode(transitionScope, forKey: .transitionScope)
        try values.encode(String(lastGlobalWakeTime), forKey: .lastGlobalWakeTime)
        try values.encode(String(lastGlobalSleepTime), forKey: .lastGlobalSleepTime)
        try values.encode(String(defaultActivityTime), forKey: .defaultActivityTime)
        try values.encode(String(defaultActivityNoChangeLightsTime), forKey: .defaultActivityNoChangeLightsTime)
    }
    /// Restoration is scoped to the owned display group/panels. Historical
    /// timestamps advance, and another group's activity can change global state.
    func hasSameOwnedState(as other: Self) -> Bool {
        panels == other.panels && activeID == other.activeID
            && defaultInteractive == other.defaultInteractive && defaultWakefulness == other.defaultWakefulness
    }
}

struct DisplayStateControllerIdentity: Equatable, Sendable {
    let pid: Int32
    let startTicks: UInt64
}

/// Separate from the legacy Boolean-panel acknowledgement and its proof type.
struct DisplayStateControllerAcknowledgement: Sendable {
    enum Event: String, Decodable, Sendable { case ready, reply, retired, startupFailed = "startup_failed" }
    enum State: String, Decodable, Sendable {
        case notStarted = "NOT_STARTED", snapshotted = "SNAPSHOTTED", ready = "READY", suspended = "SUSPENDED"
        case restored = "RESTORED", yieldedExternal = "YIELDED_EXTERNAL", yieldedActivity = "YIELDED_ACTIVITY", unconfirmed = "UNCONFIRMED"
        var terminal: Bool { self == .restored || self == .yieldedExternal || self == .yieldedActivity }
    }
    enum PanelPolicy: UInt8, Sendable { case preserve, hide, show }
    let identity: DisplayStateControllerIdentity
    let event: Event
    let revision: UInt64
    let state: State
    let draining: Bool
    let mutationSettled: Bool
    let initial: DisplayStateSnapshot?
    let current: DisplayStateSnapshot?
    let ok: Bool
    let error: String
    let reason: String

    private struct Wire: Decodable {
        let version: Int
        let event: Event
        let pid: Int32
        let startTime: String
        let revision: UInt64
        let state: State
        let draining: Bool
        let mutation_settled: Bool
        let initial: DisplayStateSnapshot?
        let current: DisplayStateSnapshot?
        let ok: Bool
        let error: String
        let reason: String
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 8192,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["version", "event", "pid", "startTime", "revision", "state", "draining", "mutation_settled", "initial", "current", "ok", "error", "reason"]) else {
            throw DisplayStateProtocolError.invalidAcknowledgement
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == 2, wire.pid > 1,
              let ticks = DisplayStateWireRules.unsigned(wire.startTime), ticks > 0,
              wire.revision <= UInt64(Int64.max), DisplayStateWireRules.code(wire.error, allowsEmpty: true),
              DisplayStateWireRules.code(wire.reason), wire.ok == wire.error.isEmpty else {
            throw DisplayStateProtocolError.invalidAcknowledgement
        }
        if wire.event == .startupFailed {
            guard !wire.ok, wire.initial == nil, wire.current == nil, wire.revision == 0,
                  wire.state == .notStarted, wire.draining, wire.mutation_settled, wire.reason == "startup" else {
                throw DisplayStateProtocolError.invalidAcknowledgement
            }
        } else {
            guard let initial = wire.initial, let current = wire.current, wire.state != .notStarted else {
                throw DisplayStateProtocolError.invalidAcknowledgement
            }
            if wire.event == .ready {
                guard wire.ok, wire.state == .snapshotted, wire.revision == 0, !wire.draining,
                      wire.mutation_settled, initial == current, wire.reason == "startup" else {
                    throw DisplayStateProtocolError.invalidAcknowledgement
                }
            }
            if wire.event == .retired {
                guard wire.ok, wire.state.terminal, wire.draining, wire.mutation_settled else {
                    throw DisplayStateProtocolError.invalidAcknowledgement
                }
                if wire.state == .restored, !current.hasSameOwnedState(as: initial) {
                    throw DisplayStateProtocolError.invalidAcknowledgement
                }
            }
        }
        return Self(identity: .init(pid: wire.pid, startTicks: ticks), event: wire.event, revision: wire.revision,
            state: wire.state, draining: wire.draining, mutationSettled: wire.mutation_settled,
            initial: wire.initial, current: wire.current, ok: wire.ok, error: wire.error, reason: wire.reason)
    }

    /// A startup snapshot is not permission to start the producer. Only this
    /// correlated, settled policy reply can satisfy interactive admission.
    func validatingPolicyReply(identity expected: DisplayStateControllerIdentity, initial baseline: DisplayStateSnapshot,
                               revision expectedRevision: UInt64, requiresInteractive: Bool, policy: PanelPolicy) throws -> Self {
        guard identity == expected else { throw DisplayStateProtocolError.identityChanged }
        guard initial == baseline else { throw DisplayStateProtocolError.initialSnapshotChanged }
        guard event == .reply, ok, state == .ready, !draining, mutationSettled,
              expectedRevision > 0, revision == expectedRevision, let current,
              Set(current.panels.map(\.id)) == Set(baseline.panels.map(\.id)), current.activeID == baseline.activeID,
              !requiresInteractive || current.defaultInteractive else { throw DisplayStateProtocolError.unexpectedReply }
        if policy == .hide, !current.panels.allSatisfy({ $0.mode == .off }) {
            throw DisplayStateProtocolError.unexpectedReply
        }
        if policy == .show, !current.panels.allSatisfy({ $0.mode == ($0.id == current.activeID ? .on : .off) }) {
            throw DisplayStateProtocolError.unexpectedReply
        }
        return self
    }

    /// A typed terminal frame is retained evidence, not proof of child absence.
    /// The broker must additionally settle/observe that exact child before reuse.
    func validatingTerminal(identity expected: DisplayStateControllerIdentity, initial baseline: DisplayStateSnapshot,
                            lastConfirmedRevision: UInt64, lastAttemptedRevision: UInt64) throws -> Self {
        guard identity == expected else { throw DisplayStateProtocolError.identityChanged }
        guard initial == baseline else { throw DisplayStateProtocolError.initialSnapshotChanged }
        guard event == .retired, ok, state.terminal, draining, mutationSettled,
              lastConfirmedRevision <= lastAttemptedRevision,
              (lastConfirmedRevision...lastAttemptedRevision).contains(revision) else {
            throw DisplayStateProtocolError.unexpectedReply
        }
        return self
    }
}
#endif
