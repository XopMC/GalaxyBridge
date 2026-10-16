import Foundation
import SystemExtensions

@MainActor
final class CameraExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var status = String(localized: "CAMERA_EXTENSION_NOT_INSTALLED")
    private let identifier = "com.xopmc.GalaxyBridge.CameraExtension"
    // Preserve the existing provisioned-build activation path. macOS validates
    // signing, provisioning and user approval when processing the request.
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
        CameraExtensionPolicy.shouldReplace(
            existingVersion: existing.bundleShortVersion, existingBuild: existing.bundleVersion,
            incomingVersion: ext.bundleShortVersion, incomingBuild: ext.bundleVersion) ? .replace : .cancel
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in status = String(localized: "CAMERA_EXTENSION_APPROVAL_REQUIRED") }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let key = CameraExtensionPolicy.completionStatusKey(result)
        Task { @MainActor in
            status = NSLocalizedString(key, tableName: nil, bundle: .main,
                value: key == "CAMERA_EXTENSION_RESTART_REQUIRED"
                    ? "Restart this Mac to finish activating GalaxyBridge Camera."
                    : key == "CAMERA_EXTENSION_READY"
                        ? "GalaxyBridge Camera is ready."
                        : "Camera extension is not installed",
                comment: "Camera extension activation result")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in status = error.localizedDescription }
    }
}
