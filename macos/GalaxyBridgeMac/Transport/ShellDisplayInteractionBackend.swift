#if !GALAXYBRIDGE_APP_STORE
import Foundation

@MainActor
final class ShellDisplayInteractionBackend: PhoneDisplayInteractionBackend {
    private let provider: ShellCapabilityBridgeProvider
    private var lease: ShellCapabilityBridgeLease?
    var mayHaveMutated: Bool { lease?.displayState?.mayHaveMutated ?? false }

    init(provider: ShellCapabilityBridgeProvider) { self.provider = provider }
    func beginSnapshot() async throws {
        guard lease == nil else { throw ShellCapabilityBridgeFailure.invalidResult }
        // The cleanup handle is retained before SNAPSHOT can allocate a child.
        let reserved = try await provider.beginDisplayStateOwnership()
        lease = reserved
        do { try await provider.snapshotDisplayState(reserved) }
        catch {
            guard !Task.isCancelled, reserved.displayState?.header == nil,
                  reserved.displayState?.mayHaveMutated == false else { throw error }
            // A failed read may have created a child. Only its exact typed
            // no-start receipt can permit the existing legacy display path.
            let cleanup = Task { [provider] in try await provider.retire(reserved) }
            try await cleanup.value
            try Task.checkCancellation()
            guard reserved.displayState?.confirmedNotStarted == true else { throw error }
            lease = nil
            throw PhoneDisplayInteractionPreparationFailure.unsupportedAfterConfirmedNoStart
        }
    }
    func apply(_ policy: DisplayStateControllerAcknowledgement.PanelPolicy) async throws {
        guard let lease else { throw ShellCapabilityBridgeFailure.invalidResult }
        try await provider.applyDisplayState(lease, policy: policy)
    }
    func poll() async throws {
        guard let lease else { throw ShellCapabilityBridgeFailure.invalidResult }
        try await provider.pollDisplayState(lease)
    }
    func retire() async throws {
        guard let lease else { return }
        try await provider.retire(lease)
        self.lease = nil
    }
}
#endif
