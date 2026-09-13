import Foundation

@MainActor
final class CompanionConnectingWatchdog {
    private let timeout: Duration
    private let onTimeout: @MainActor (String) -> Void
    private var tasks: [String: Task<Void, Never>] = [:]

    init(
        timeout: Duration = .seconds(2),
        onTimeout: @escaping @MainActor (String) -> Void
    ) {
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    func connectionStarted(companionID: String) {
        connectionSettled(companionID: companionID)
        tasks[companionID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            tasks.removeValue(forKey: companionID)
            onTimeout(companionID)
        }
    }

    func connectionSettled(companionID: String) {
        tasks.removeValue(forKey: companionID)?.cancel()
    }

    func forget(companionID: String) {
        connectionSettled(companionID: companionID)
    }
}
