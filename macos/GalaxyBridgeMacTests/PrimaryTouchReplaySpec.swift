import Foundation

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

@main enum PrimaryTouchReplaySpec {
    @MainActor static func main() async {
        let arguments = ["--primary-media-diagnostics", "--primary-input-marker-nonce=270544960", "--qa-touch-replay-peer=device:fixture"]
        let config = PrimaryTouchReplayConfiguration.parse(arguments)!
        precondition(config.peerID == "device:fixture" && config.nonce == 270544960)
        for invalid in [Array(arguments.dropFirst()), Array(arguments.dropLast()), arguments + [arguments.last!],
                        arguments + ["--primary-input-marker-nonce=7"],
                        [arguments[0], arguments[1], "--qa-touch-replay-peer=unscoped"],
                        [arguments[0], arguments[1], "--qa-touch-replay-peer=device:invalid peer"]] {
            precondition(PrimaryTouchReplayConfiguration.parse(invalid) == nil)
        }
        let plan = PrimaryTouchReplayEvent.plan
        precondition(plan.count == 50 && plan.first!.action == .down && plan.last!.action == .up)
        precondition(plan.filter { $0.action == .move }.count == 48)
        precondition(plan.compactMap(\.counter) == Array(UInt16(1)...UInt16(49)))
        precondition(plan.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        precondition(zip(plan, plan.dropFirst()).allSatisfy { $0.offset < $1.offset })
        precondition(plan.last!.pressure == 0 && plan.first!.pressure == 0x8001)
        do {
            let clock = Clock(); var events: [PrimaryTouchReplayEvent] = [], results: [PrimaryTouchReplay.Result] = []
            let replay = PrimaryTouchReplay(configuration: config, now: { clock.now() }, sleep: { clock.advance($0) }, completed: { results.append($0) })
            let attempt = UUID()
            replay.observe(peerID: "device:other", attemptID: attempt, markerReady: true) { _ in preconditionFailure("Wrong peer injected input") }
            replay.observe(peerID: config.peerID, attemptID: attempt, markerReady: false) { _ in preconditionFailure("Unproven picture injected input") }
            await replay.waitForCompletion(); precondition(results.isEmpty)
            replay.observe(peerID: config.peerID, attemptID: attempt, markerReady: true) { events.append($0); return true }
            await replay.waitForCompletion()
            precondition(events.count == 50 && results.count == 1 && results[0].reason == .complete)
            precondition(results[0].down == 1 && results[0].moves == 48 && results[0].up == 1 && !results[0].cancelQueued)
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true) { _ in preconditionFailure("Reconnect replayed the gesture") }
            await replay.waitForCompletion(); precondition(results.count == 1)
        }
        do {
            let clock = Clock(); var events: [PrimaryTouchReplayEvent] = [], result: PrimaryTouchReplay.Result?
            var replay: PrimaryTouchReplay!
            replay = PrimaryTouchReplay(configuration: config, now: { clock.now() }, sleep: { clock.advance($0) }, completed: { result = $0 })
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true) {
                events.append($0); if $0.counter == 6 { replay.cancel() }; return true
            }
            await replay.waitForCompletion()
            precondition(result?.reason == .cancelled && result?.cancelQueued == true)
            precondition(events.last?.action == .cancel && events.filter { $0.action == .down }.count == 1)
            precondition(events.count == 7, "Cancellation must fence every later MOVE and send one release")
        }
        do {
            let clock = Clock(); var events: [PrimaryTouchReplayEvent] = [], result: PrimaryTouchReplay.Result?
            let replay = PrimaryTouchReplay(configuration: config, now: { clock.now() }, sleep: { clock.advance($0 + 0.3) }, completed: { result = $0 })
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true) { events.append($0); return true }
            await replay.waitForCompletion()
            precondition(result?.reason == .generatorStalled && result?.cancelQueued == true)
            precondition(events.map(\.action) == [.down, .cancel], "A stalled generator cannot manufacture a burst of catch-up input")
        }
        do {
            let clock = Clock(); var events: [PrimaryTouchReplayEvent] = [], result: PrimaryTouchReplay.Result?
            let replay = PrimaryTouchReplay(configuration: config, now: { clock.now() }, sleep: { clock.advance($0 + 0.075) }, completed: { result = $0 })
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true) { events.append($0); return true }
            await replay.waitForCompletion()
            precondition(result?.reason == .generatorStalled && events.map(\.action) == [.down, .cancel],
                "A moderate pause must invalidate the 60Hz workload, never complete with overdue MOVE bursts")
        }
        do {
            let clock = Clock(); var calls = 0; var result: PrimaryTouchReplay.Result?
            let replay = PrimaryTouchReplay(configuration: config, now: { clock.now() }, sleep: { clock.advance($0) }, completed: { result = $0 })
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true) { _ in calls += 1; return false }
            await replay.waitForCompletion()
            precondition(calls == 1 && result?.reason == .sourceChanged && result?.down == 0 && result?.cancelQueued == false)
        }
        do {
            let clock = Clock(); let initial = CGSize(width: 640, height: 1280)
            var current = initial; var sizes: [CGSize] = []; var actions: [PrimaryTouchReplayEvent.Action] = []
            var result: PrimaryTouchReplay.Result?; var retirements = 0
            let replay = PrimaryTouchReplay(configuration: config, now: { clock.now() }, sleep: { clock.advance($0) }, completed: { result = $0 })
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true, retire: { retirements += 1 }) { event in
                guard let size = event.deliverySize(initial: initial, current: current) else { return false }
                actions.append(event.action); sizes.append(size)
                if event.action == .down { current = CGSize(width: 800, height: 1600) }
                return true
            }
            await replay.waitForCompletion()
            precondition(result?.reason == .sourceChanged && result?.cancelQueued == true && retirements == 0)
            precondition(actions == [.down, .cancel] && sizes == [initial, current], "A same-attempt resize must release with current valid geometry")
        }
        do {
            let clock = Clock(); var delivered: [PrimaryTouchReplayEvent.Action] = [], result: PrimaryTouchReplay.Result?
            var retirements = 0
            let replay = PrimaryTouchReplay(configuration: config, now: { clock.now() }, sleep: { clock.advance($0) }, completed: { result = $0 })
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true, retire: { retirements += 1 }) { event in
                guard event.action == .down else { return false }; delivered.append(.down); return true
            }
            await replay.waitForCompletion()
            precondition(delivered == [.down] && result?.cancelQueued == false && result?.retirementRequested == true && retirements == 1,
                "An admitted DOWN with no deliverable release must request exact producer retirement once")
        }
        do {
            var calls = 0; var result: PrimaryTouchReplay.Result?
            let replay = PrimaryTouchReplay(configuration: config, completed: { result = $0 })
            replay.observe(peerID: config.peerID, attemptID: UUID(), markerReady: true) { _ in calls += 1; return true }
            replay.cancel(); await replay.waitForCompletion()
            precondition(calls == 0 && result?.reason == .cancelled, "Cancellation before task admission cannot emit DOWN")
        }
        print("PASS dense input probe: exact peer and marker gate, 48 moves at 60Hz, one shot, bounded stall, source fencing and release")
    }
}
