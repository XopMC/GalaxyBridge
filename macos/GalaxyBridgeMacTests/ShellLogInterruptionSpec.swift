import Foundation
import OSLog

@MainActor final class DisplayOwner {
    var applicationDisplayLaunchGeneration: ScrcpyApplicationDisplayLaunchGeneration?
    var applicationDisplayIdentity: ScrcpyApplicationDisplayIdentity?
    var applicationDisplayIdentityConflicted = false
    var serverOutputObserver: ScrcpyOwnedProcessOutputObserver?
    let logger = Logger(subsystem: "GalaxyBridge.tests", category: "display-observation")
    var endedEvents = 0
    // ACTUAL_DISPLAY_EVENT_HANDLER
}
// ACTUAL_LOG_STATE_HANDLER
@main enum ShellLogInterruptionSpec {
    @MainActor static func main() async throws {
        for state: CompanionConnectionState in [.transportInterrupted("socket EOF"), .failed("bad frame"), .authenticationRejected("revoked"), .disconnected] {
            let owner = DisplayOwner(), generation = ScrcpyApplicationDisplayLaunchGeneration()
            owner.applicationDisplayLaunchGeneration = generation
            let observer = try ScrcpyOwnedProcessOutputObserver { [weak owner] event in
                Task { @MainActor in
                    if case .ended = event { owner?.endedEvents += 1 }
                    owner?.handleApplicationDisplayOutput(event, generation: generation)
                }
            }
            owner.serverOutputObserver = observer
            observer.receive(Data("[server] INFO: New display: 800x1200/240 (id=17)\n".utf8))
            for _ in 0..<100 {
                if owner.applicationDisplayIdentity != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(owner.applicationDisplayIdentity?.displayID == 17, "Owned log did not establish display identity")
            actualLogState(.connecting, outputObserver: observer)
            actualLogState(.connected, outputObserver: observer)
            precondition(owner.endedEvents == 0, "Non-terminal log state invalidated the live display")
            actualLogState(state, outputObserver: observer)
            for _ in 0..<100 {
                if owner.endedEvents > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(owner.endedEvents == 1 && owner.applicationDisplayIdentity == nil
                && owner.applicationDisplayLaunchGeneration == nil && owner.serverOutputObserver == nil,
                "Terminal log state retained a trusted application display identity")
            actualLogState(state, outputObserver: observer)
            _ = observer.isIdle
            try await Task.sleep(for: .milliseconds(10))
            precondition(owner.endedEvents == 1, "Repeated log termination emitted duplicate ended events")
        }
        print("PASS actual shell-log callback and observer: every terminal state invalidates exact app-display generation once")
    }
}
