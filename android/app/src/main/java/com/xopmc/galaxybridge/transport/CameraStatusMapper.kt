package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.CameraCaptureState
import com.xopmc.galaxybridge.protocol.v1.CameraStatus
import com.xopmc.galaxybridge.service.CameraCapturePhase
import com.xopmc.galaxybridge.service.CameraCaptureStatus

internal object CameraStatusMapper {
    fun toProtocol(status: CameraCaptureStatus): CameraStatus = CameraStatus.newBuilder()
        .setRequestId(status.requestId)
        .setState(
            when (status.phase) {
                CameraCapturePhase.STARTING -> CameraCaptureState.CAMERA_CAPTURE_STATE_STARTING
                CameraCapturePhase.AWAITING_USER_CONFIRMATION ->
                    CameraCaptureState.CAMERA_CAPTURE_STATE_AWAITING_USER_CONFIRMATION
                CameraCapturePhase.STREAMING -> CameraCaptureState.CAMERA_CAPTURE_STATE_STREAMING
                CameraCapturePhase.STOPPED -> CameraCaptureState.CAMERA_CAPTURE_STATE_STOPPED
                CameraCapturePhase.FAILED -> CameraCaptureState.CAMERA_CAPTURE_STATE_FAILED
            },
        )
        .setReasonCode(status.reasonCode)
        .setRetryable(status.retryable)
        .build()
}
