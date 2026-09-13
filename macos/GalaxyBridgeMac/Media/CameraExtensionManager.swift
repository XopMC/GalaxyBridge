import Foundation
import SystemExtensions

@MainActor
final class CameraExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var status = String(localized: "CAMERA_EXTENSION_NOT_INSTALLED")
    private let identifier = "com.xopmc.GalaxyBridge.CameraExtension"
    let supportsActivation = Bundle.main.object(forInfoDictionaryKey: "GalaxyBridgeDistribution") as? String != "github-direct"

    func activate() {
        guard supportsActivation else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            status = String(localized: "CAMERA_EXTENSION_APPLICATIONS_REQUIRED")
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        status = String(localized: "CAMERA_EXTENSION_ACTIVATING")
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        ext.bundleShortVersion > existing.bundleShortVersion ? .replace : .cancel
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in status = String(localized: "CAMERA_EXTENSION_APPROVAL_REQUIRED") }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in status = String(localized: "CAMERA_EXTENSION_READY") }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in status = error.localizedDescription }
    }
}
