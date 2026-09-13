import AppKit

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
    private var cleanupTask: Task<Void, Never>?

    @discardableResult
    func begin(
        cleanup: @escaping @MainActor @Sendable () async -> Void,
        reply: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard cleanupTask == nil else { return false }
        cleanupTask = Task {
            await cleanup()
            reply()
        }
        return true
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
