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
        try await provider.snapshotDisplayState(reserved)
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
