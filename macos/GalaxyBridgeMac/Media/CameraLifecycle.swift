import Foundation
import OSLog

enum CameraRetirementReason: String, Equatable, Sendable {
    case stop
    case replacement
    case generationLoss = "generation_loss"
    case remoteStopped = "remote_stopped"
    case remoteFailed = "remote_failed"
    case startFailed = "start_failed"
    case pairingRevoked = "pairing_revoked"
    case quit
    case publicationFailure = "publication_failure"
}

/// Pure local reducer. Its containing permit supplies the immutable attempt,
/// owner, authenticated connection generation and request identity. Remote
/// STREAMING is intentionally not an input that can enter `publishing`.
struct CameraLifecycleState: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case starting, publishing, retiring, retired
        case cleanupFailed = "cleanup_failed"
    }
    private(set) var phase: Phase = .starting
    private(set) var retirementReason: CameraRetirementReason?

    mutating func publish() -> Bool {
        guard phase == .starting, retirementReason == nil else { return false }
        phase = .publishing
        return true
    }

    mutating func retire(reason: CameraRetirementReason) -> Bool {
        guard retirementReason == nil || phase == .cleanupFailed else { return false }
        retirementReason = retirementReason ?? reason
        phase = .retiring
        return true
    }

    mutating func completeRetirement(succeeded: Bool) -> Bool {
        guard phase == .retiring else { return false }
        phase = succeeded ? .retired : .cleanupFailed
        return true
    }
}

/// Only fixed categories and process-local numbers can cross this diagnostic
/// boundary. There is no identity, arbitrary string/error, frame or history.
struct CameraLifecycleDiagnostic: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case started, publishing, retiring, retired
        case cleanupFailed = "cleanup_failed"
    }
    let kind: Kind
    let attemptOrdinal: UInt64
    let connectionGeneration: UInt64
    let reason: CameraRetirementReason?
    let elapsedMilliseconds: UInt64

    var serialized: String {
        "event=\(kind.rawValue) attempt=\(attemptOrdinal) generation=\(connectionGeneration) reason=\(reason?.rawValue ?? "none") elapsed_ms=\(elapsedMilliseconds)"
    }

    static func log(_ event: Self) {
        let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "CameraLifecycle")
        if event.kind == .cleanupFailed { logger.error("\(event.serialized, privacy: .public)") }
        else { logger.notice("\(event.serialized, privacy: .public)") }
    }
}
