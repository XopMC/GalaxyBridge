#if GB_INPUT_REPLAY_QA && !GALAXYBRIDGE_APP_STORE
import Foundation
import OSLog

struct PrimaryTouchReplayConfiguration: Sendable {
    let peerID: String
    let nonce: UInt32
    static let process = parse(ProcessInfo.processInfo.arguments)

    static func parse(_ arguments: [String]) -> Self? {
        let prefix = "--qa-touch-replay-peer"
        let matches = arguments.filter { $0.hasPrefix(prefix) }
        guard arguments.contains("--primary-media-diagnostics"), matches.count == 1,
              matches[0].hasPrefix(prefix + "="),
              case let .enabled(nonce) = PrimaryInputMarkerConfiguration.parse(arguments) else { return nil }
        let peer = String(matches[0].dropFirst(prefix.count + 1))
        guard peer.hasPrefix("device:"), (8...160).contains(peer.utf8.count),
              peer.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
        return Self(peerID: peer, nonce: nonce)
    }
}

struct PrimaryTouchReplayEvent: Sendable {
    enum Action: UInt8, Sendable { case down = 0, up = 1, move = 2, cancel = 3 }
    let action: Action
    let counter: UInt16?
    let offset: Double
    let x: Double
    let y: Double
    var pressure: UInt16 { counter.map { 0x8000 + $0 } ?? 0 }

    func deliverySize(initial: CGSize, current: CGSize) -> CGSize? {
        guard current.width.isFinite, current.height.isFinite,
              (1...65535).contains(current.width), (1...65535).contains(current.height),
              action == .cancel || current == initial else { return nil }
        return current
    }

    static var plan: [Self] {
        var result = [Self(action: .down, counter: 1, offset: 0, x: 0.5, y: 0.8)]
        for index in 1...48 {
            result.append(Self(action: .move, counter: UInt16(index + 1), offset: Double(index) / 60,
                               x: 0.5, y: 0.8 - Double(index) * 0.6 / 48))
        }
        result.append(Self(action: .up, counter: nil, offset: 49.0 / 60, x: 0.5, y: 0.2))
        return result
    }

    static func qualifies(_ data: Data) -> Bool {
        guard data.count == 32 else { return false }
        let bytes = Array(data)
        let pressure = UInt16(bytes[22]) << 8 | UInt16(bytes[23])
        return bytes[0] == 2 && (bytes[1] == 0 || bytes[1] == 2)
            && bytes[2..<10].reduce(UInt64(0), { ($0 << 8) | UInt64($1) }) == UInt64.max - 1
            && (0x8001...0x8100).contains(pressure)
    }
}

@MainActor
final class PrimaryTouchReplay {
    struct Result: Sendable {
        enum Reason: String, Sendable { case complete, cancelled, sourceChanged, generatorStalled }
        let reason: Reason
        let down: Int
        let moves: Int
        let up: Int
        let cancelQueued: Bool
        let retirementRequested: Bool
        let maximumLatenessMS: Double
    }
    private let configuration: PrimaryTouchReplayConfiguration?
    private let now: @Sendable () -> Double
    private let sleep: @Sendable (Double) async throws -> Void
    private let completed: @MainActor (Result) -> Void
    private let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "PrimaryTouchReplay")
    private var task: Task<Void, Never>?
    private var attempt: UUID?
    private var started = false
    private var admissionOpen = true

    init(configuration: PrimaryTouchReplayConfiguration? = .process,
         now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         completed: @escaping @MainActor (Result) -> Void = { _ in }) {
        self.configuration = configuration; self.now = now; self.sleep = sleep; self.completed = completed
    }

    func observe(peerID: String, attemptID: UUID, markerReady: Bool,
                 retire: @escaping @MainActor () -> Void = {},
                 send: @escaping @MainActor (PrimaryTouchReplayEvent) -> Bool) {
        guard let configuration, peerID == configuration.peerID else { return }
        if started {
            if attempt != attemptID { cancel() }
            return
        }
        guard admissionOpen, markerReady else { return }
        started = true; attempt = attemptID
        task = Task { [weak self] in
            guard let self else { return }
            let start = now()
            var down = 0, moves = 0, up = 0
            var maximumLatenessMS = 0.0
            var reason = Result.Reason.complete
            var last = PrimaryTouchReplayEvent.plan[0]
            do {
                for event in PrimaryTouchReplayEvent.plan {
                    let remaining = start + event.offset - now()
                    if remaining > 0 { try await sleep(remaining) }
                    try Task.checkCancellation()
                    guard admissionOpen else { throw CancellationError() }
                    maximumLatenessMS = max(maximumLatenessMS, max(0, now() - start - event.offset) * 1_000)
                    if maximumLatenessMS >= 1_000.0 / 60 { reason = .generatorStalled; break }
                    guard send(event) else { reason = .sourceChanged; break }
                    last = event
                    switch event.action { case .down: down += 1; case .move: moves += 1; case .up: up += 1; case .cancel: break }
                }
            } catch { reason = .cancelled }
            var released = false
            if down > 0 && up == 0 {
                released = send(.init(action: .cancel, counter: nil, offset: 0, x: last.x, y: last.y))
            }
            let needsRetirement = down > 0 && up == 0 && !released
            if needsRetirement { retire() }
            let result = Result(reason: reason, down: down, moves: moves, up: up,
                                cancelQueued: released, retirementRequested: needsRetirement, maximumLatenessMS: maximumLatenessMS)
            logger.notice("touch_replay reason=\(reason.rawValue, privacy: .public) down=\(down) moves=\(moves) up=\(up) cancel_queued=\(released) retirement_requested=\(needsRetirement) maximum_lateness_ms=\(maximumLatenessMS)")
            completed(result)
        }
    }

    func cancel() { admissionOpen = false; task?.cancel() }
    func waitForCompletion() async { await task?.value }
}
#endif
