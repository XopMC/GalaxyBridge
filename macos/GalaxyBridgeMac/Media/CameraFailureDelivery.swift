import Foundation
import OSLog

/// Errors remain observable in the log during termination; UI delivery is
/// coalesced so a blocked MainActor cannot accumulate one task per failed frame.
final class CameraFailureDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (message: String, permit: CameraPublicationPermit?)?
    private var scheduled = false
    private let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "camera-publication")
    private let deliver: @MainActor @Sendable (String, CameraPublicationPermit?) -> Void

    init(deliver: @escaping @MainActor @Sendable (String, CameraPublicationPermit?) -> Void) { self.deliver = deliver }

    func report(_ error: Error, permit: CameraPublicationPermit?) {
        let message = error.localizedDescription
        // Error descriptions can contain paths, endpoints or other private
        // data. The UI keeps the actionable error; lifecycle diagnostics carry
        // fixed reason/completion categories through the retirement barrier.
        logger.error("Camera pipeline reported an error")
        lock.withLock {
            pending = (message, permit)
            guard !scheduled else { return }
            scheduled = true
            Task { @MainActor [self] in
                let message = lock.withLock {
                    let value = pending
                    pending = nil
                    scheduled = false
                    return value
                }
                if let message { deliver(message.message, message.permit) }
            }
        }
    }
}
