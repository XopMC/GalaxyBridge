import Foundation

@main
struct CameraStatusViewStateSpec {
    static func main() {
        let pending = CameraStatusViewState.resolve(
            phase: .awaitingUserConfirmation,
            reasonCode: "camera_confirmation_required"
        )
        precondition(pending.titleKey == "CAMERA_STATUS_CONFIRM_ON_PHONE")
        precondition(pending.detailKey == "CAMERA_STATUS_CONFIRM_ON_PHONE_DETAIL")
        precondition(pending.symbolName == "iphone.gen3.badge.exclamationmark")
        precondition(!pending.isFailure)

        let permission = CameraStatusViewState.resolve(
            phase: .failed,
            reasonCode: "camera_permission_required"
        )
        precondition(permission.titleKey == "CAMERA_STATUS_PERMISSION_REQUIRED")
        precondition(permission.isFailure)

        let failed = CameraStatusViewState.resolve(
            phase: .failed,
            reasonCode: "camera_encoder_failed"
        )
        precondition(failed.titleKey == "CAMERA_STATUS_FAILED")
        precondition(failed.detailKey == "CAMERA_STATUS_FAILED_DETAIL")

        precondition(CameraStatusViewState.resolve(phase: .streaming, reasonCode: "").titleKey == "CAMERA_STATUS_PRODUCER_READY", "Remote STREAMING cannot assert successful local publication")
        precondition(!CameraStatusCorrelation.accepts(currentRequestID: nil, incomingRequestID: "old"), "A missing request must not admit unsolicited or stale status")
        precondition(CameraStatusCorrelation.accepts(currentRequestID: "new", incomingRequestID: "new"))
        precondition(!CameraStatusCorrelation.accepts(currentRequestID: "new", incomingRequestID: "old"))

        var publishing = CameraLifecycleState()
        precondition(publishing.publish())
        let retained = CameraStatusViewState.resolveRetained(
            remoteStatuses: ["current": .init(phase: .streaming, reasonCode: ""), "removed": .init(phase: .streaming, reasonCode: "")],
            localStates: ["current": publishing]
        )
        precondition(retained.count == 1 && retained["removed"] == nil)
        precondition(retained["current"]?.titleKey == "CAMERA_STATUS_STREAMING")

        print("PASS camera status presentation and request correlation")
    }
}
