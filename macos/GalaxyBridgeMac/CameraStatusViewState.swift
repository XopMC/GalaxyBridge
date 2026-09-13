import Foundation

enum CameraRemotePhase: Equatable, Sendable {
    case starting
    case awaitingUserConfirmation
    case streaming
    case stopped
    case failed
}

/// Current command's producer state only; never grants local ownership.
struct CameraRemoteStatus: Equatable, Sendable {
    private(set) var phase: CameraRemotePhase
    private(set) var reasonCode: String
    var serviceMayBeRunning: Bool {
        phase == .starting || phase == .awaitingUserConfirmation || phase == .streaming
    }

    init(phase: CameraRemotePhase, reasonCode: String) {
        self.phase = phase
        self.reasonCode = Self.allowedReason(reasonCode)
    }

    mutating func receive(phase next: CameraRemotePhase, reasonCode: String) -> Bool {
        guard phase != .stopped, phase != .failed else { return false }
        if next == .starting { return false }
        if phase == .streaming && next == .awaitingUserConfirmation { return false }
        let reason = Self.allowedReason(reasonCode)
        guard next != phase || reason != self.reasonCode else { return false }
        phase = next
        self.reasonCode = reason
        return true
    }

    private static func allowedReason(_ code: String) -> String {
        switch code {
        case "camera_permission_required", "camera_confirmation_unavailable", "camera_confirmation_cancelled": code
        default: ""
        }
    }
}

struct CameraStatusViewState: Equatable, Sendable {
    let titleKey: String
    let detailKey: String?
    let symbolName: String
    let isFailure: Bool
    var remoteServiceMayBeRunning: Bool = false

    /// One coalesced notification can cover cleanup on A and publication on B.
    /// Re-read only retained current states; a late notification carries no
    /// authority to restore a removed device or replace a newer attempt.
    static func resolveRetained(remoteStatuses: [String: CameraRemoteStatus],
                                localStates: [String: CameraLifecycleState]) -> [String: Self] {
        var statuses: [String: Self] = [:]
        for (deviceID, local) in localStates {
            guard let remote = remoteStatuses[deviceID] else { continue }
            statuses[deviceID] = resolve(remote: remote, local: local)
        }
        return statuses
    }

    static func resolve(remote: CameraRemoteStatus, local: CameraLifecycleState?) -> Self {
        var result: Self
        if local?.phase == .cleanupFailed {
            result = Self(titleKey: "CAMERA_STATUS_CLEANUP_FAILED", detailKey: "CAMERA_STATUS_CLEANUP_FAILED_DETAIL", symbolName: "exclamationmark.triangle", isFailure: true)
        } else if let local, let reason = local.retirementReason {
            if reason == .remoteFailed {
                result = resolve(phase: .failed, reasonCode: remote.reasonCode)
            } else if (reason == .stop || reason == .remoteStopped) && !remote.serviceMayBeRunning {
                result = resolve(phase: .stopped, reasonCode: "")
            } else {
                result = Self(titleKey: "CAMERA_STATUS_RESTART_REQUIRED", detailKey: remote.serviceMayBeRunning ? "CAMERA_STATUS_RESTART_REQUIRED_RUNNING_DETAIL" : "CAMERA_STATUS_RESTART_REQUIRED_DETAIL", symbolName: "video.slash", isFailure: reason == .startFailed || reason == .publicationFailure)
            }
        } else if local?.phase == .publishing {
            result = Self(titleKey: "CAMERA_STATUS_STREAMING", detailKey: "CAMERA_STATUS_STREAMING_DETAIL", symbolName: "video.fill", isFailure: false)
        } else if local == nil && remote.serviceMayBeRunning {
            result = Self(titleKey: "CAMERA_STATUS_RESTART_REQUIRED", detailKey: "CAMERA_STATUS_RESTART_REQUIRED_RUNNING_DETAIL", symbolName: "video.slash", isFailure: false)
        } else {
            result = resolve(phase: remote.phase, reasonCode: remote.reasonCode)
        }
        result.remoteServiceMayBeRunning = remote.serviceMayBeRunning
        return result
    }

    static func resolve(phase: CameraRemotePhase, reasonCode: String) -> Self {
        return switch phase {
        case .starting:
            Self(
                titleKey: "CAMERA_STATUS_STARTING",
                detailKey: "CAMERA_STATUS_STARTING_DETAIL",
                symbolName: "video.badge.ellipsis",
                isFailure: false
            )
        case .awaitingUserConfirmation:
            Self(
                titleKey: "CAMERA_STATUS_CONFIRM_ON_PHONE",
                detailKey: "CAMERA_STATUS_CONFIRM_ON_PHONE_DETAIL",
                symbolName: "iphone.gen3.badge.exclamationmark",
                isFailure: false
            )
        case .streaming:
            Self(
                titleKey: "CAMERA_STATUS_PRODUCER_READY",
                detailKey: "CAMERA_STATUS_PRODUCER_READY_DETAIL",
                symbolName: "video.badge.ellipsis",
                isFailure: false
            )
        case .stopped:
            Self(
                titleKey: "CAMERA_STATUS_STOPPED",
                detailKey: nil,
                symbolName: "video.slash",
                isFailure: false
            )
        case .failed:
            switch reasonCode {
            case "camera_permission_required":
                Self(
                    titleKey: "CAMERA_STATUS_PERMISSION_REQUIRED",
                    detailKey: "CAMERA_STATUS_PERMISSION_REQUIRED_DETAIL",
                    symbolName: "video.badge.exclamationmark",
                    isFailure: true
                )
            case "camera_confirmation_unavailable":
                Self(
                    titleKey: "CAMERA_STATUS_CONFIRMATION_UNAVAILABLE",
                    detailKey: "CAMERA_STATUS_CONFIRMATION_UNAVAILABLE_DETAIL",
                    symbolName: "bell.slash",
                    isFailure: true
                )
            case "camera_confirmation_cancelled":
                Self(
                    titleKey: "CAMERA_STATUS_CANCELLED",
                    detailKey: nil,
                    symbolName: "xmark.circle",
                    isFailure: true
                )
            default:
                Self(
                    titleKey: "CAMERA_STATUS_FAILED",
                    detailKey: "CAMERA_STATUS_FAILED_DETAIL",
                    symbolName: "exclamationmark.triangle",
                    isFailure: true
                )
            }
        }
    }
}

enum CameraStatusCorrelation {
    static func accepts(currentRequestID: String?, incomingRequestID: String) -> Bool {
        guard let currentRequestID, !currentRequestID.isEmpty, !incomingRequestID.isEmpty else { return false }
        return currentRequestID == incomingRequestID
    }
}
