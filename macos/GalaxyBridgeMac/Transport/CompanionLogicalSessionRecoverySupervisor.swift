import Foundation

@MainActor
final class CompanionLogicalSessionRecoverySupervisor {
    typealias Generation = UInt64

    struct DelayedRetryPermit: Equatable {
        fileprivate let companionID: String
        fileprivate let generation: Generation
        fileprivate let identity = UUID()
    }

    private struct RetrySlot {
        let permit: DelayedRetryPermit
        let cancel: () -> Void
    }

    private var nextGeneration: Generation = 0
    private var currentGenerations: [String: Generation] = [:]
    private var pendingRecoveries: [String: DelayedRetryPermit] = [:]
    private var retrySlots: [String: RetrySlot] = [:]
    private var isTerminal = false

    func beginSession(companionID: String) -> Generation? {
        guard !isTerminal else { return nil }
        cancelDelayedRetry(companionID: companionID)
        nextGeneration &+= 1
        currentGenerations[companionID] = nextGeneration
        return nextGeneration
    }

    func requestRecovery(companionID: String, generation: Generation) -> DelayedRetryPermit? {
        guard !isTerminal, currentGenerations[companionID] == generation else { return nil }
        guard pendingRecoveries[companionID] == nil else { return nil }
        let permit = DelayedRetryPermit(companionID: companionID, generation: generation)
        pendingRecoveries[companionID] = permit
        currentGenerations.removeValue(forKey: companionID)
        return permit
    }

    @discardableResult
    func recover(
        companionID: String,
        generation: Generation,
        cancelChannels: [() -> Void],
        scheduleDelayedReconnect: (DelayedRetryPermit) -> Void,
        publishModel: (Bool) -> Void
    ) -> Bool {
        guard let permit = requestRecovery(companionID: companionID, generation: generation) else { return false }
        cancelChannels.forEach { $0() }
        scheduleDelayedReconnect(permit)
        publishModel(false)
        return true
    }

    func currentGeneration(companionID: String) -> Generation? {
        currentGenerations[companionID]
    }

    @discardableResult
    func ifCurrentSession(
        companionID: String,
        generation: Generation,
        perform action: () -> Void
    ) -> Bool {
        guard currentGenerations[companionID] == generation else { return false }
        action()
        return true
    }

    func forget(companionID: String) {
        currentGenerations.removeValue(forKey: companionID)
        cancelDelayedRetry(companionID: companionID)
    }

    // Synchronous and one-way, including cancellation of every retained task.
    func beginApplicationTermination() {
        isTerminal = true
        currentGenerations.removeAll()
        pendingRecoveries.removeAll()
        let slots = Array(retrySlots.values)
        retrySlots.removeAll()
        slots.forEach { $0.cancel() }
    }

    var delayedRetryCount: Int { retrySlots.count }

    func hasDelayedRetry(companionID: String) -> Bool {
        retrySlots[companionID] != nil
    }

    func admitsDelayedRetry(_ permit: DelayedRetryPermit) -> Bool {
        !isTerminal && pendingRecoveries[permit.companionID] == permit
    }

    @discardableResult
    func installDelayedRetry(_ permit: DelayedRetryPermit, cancel: @escaping () -> Void) -> Bool {
        guard admitsDelayedRetry(permit), retrySlots[permit.companionID] == nil else {
            cancel()
            return false
        }
        retrySlots[permit.companionID] = RetrySlot(permit: permit, cancel: cancel)
        return true
    }

    // Validate the exact permit before either removing a slot or invoking merge.
    // MainActor isolation keeps consumption and the action in one synchronous turn.
    @discardableResult
    func performDelayedRetry(_ permit: DelayedRetryPermit, perform action: () -> Void) -> Bool {
        guard admitsDelayedRetry(permit), retrySlots[permit.companionID]?.permit == permit else { return false }
        pendingRecoveries.removeValue(forKey: permit.companionID)
        retrySlots.removeValue(forKey: permit.companionID)
        action()
        return true
    }

    func cancelDelayedRetry(companionID: String) {
        pendingRecoveries.removeValue(forKey: companionID)
        let slot = retrySlots.removeValue(forKey: companionID)
        slot?.cancel()
    }
}
