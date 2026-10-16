import AppKit
import OSLog

struct ApplicationTerminationAdmission {
    private(set) var isTerminating = false

    var admitsWork: Bool { !isTerminating }

    mutating func begin() -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        return true
    }
}

@MainActor
final class ApplicationTerminationCleanupCoordinator {
    private let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "termination")
    private let waitForDeadline: @Sendable () async throws -> Void
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var hasBegun = false
    private var hasReplied = false

    init(waitForDeadline: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(10))
    }) {
        self.waitForDeadline = waitForDeadline
    }

    @discardableResult
    func begin(
        cleanup: @escaping @MainActor @Sendable () async -> Void,
        reply: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard !hasBegun else { return false }
        hasBegun = true
        // This is an independent task, not a task-group race: leaving a group
        // would still await a child blocked inside uncancellable filesystem IO.
        deadlineTask = Task {
            do { try await waitForDeadline() }
            catch { return }
            finish(timedOut: true, reply: reply)
        }
        cleanupTask = Task {
            await cleanup()
            finish(timedOut: false, reply: reply)
        }
        return true
    }

    private func finish(timedOut: Bool, reply: @MainActor @Sendable () -> Void) {
        guard !hasReplied else { return }
        hasReplied = true
        deadlineTask?.cancel()
        deadlineTask = nil
        if timedOut {
            // Cancellation requests cooperation, but must never delay AppKit's
            // reply while TCC, a file provider, or filesystem IO remains blocked.
            cleanupTask?.cancel()
            logger.error("Application termination cleanup exceeded its deadline; allowing requested termination with incomplete cleanup")
        }
        cleanupTask = nil
        reply()
    }
}

@MainActor
final class GalaxyBridgeApplicationDelegate: NSObject, NSApplicationDelegate {
    private let terminationCleanup = ApplicationTerminationCleanupCoordinator()
    private var cleanupHandler: (@MainActor @Sendable () async -> Void)?

    func installCleanupHandler(_ handler: @escaping @MainActor @Sendable () async -> Void) {
        cleanupHandler = handler
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let cleanupHandler else { return .terminateNow }
        terminationCleanup.begin(
            cleanup: cleanupHandler,
            reply: { sender.reply(toApplicationShouldTerminate: true) }
        )
        return .terminateLater
    }
}
