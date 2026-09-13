package com.xopmc.galaxybridge.service

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class CameraCaptureRequest(
    val requestId: String,
    val enabled: Boolean,
    val cameraId: String,
    val width: Int,
    val height: Int,
    val framesPerSecond: Int,
)

internal enum class CameraStartAttempt {
    ACCEPTED,
    BACKGROUND_RESTRICTED,
    PERMISSION_MISSING,
    FAILED,
}

internal object CameraStartFailureClassifier {
    fun classify(
        cameraPermissionGranted: Boolean,
        errorClassName: String,
        securityException: Boolean,
    ): CameraStartAttempt {
        if (!cameraPermissionGranted) return CameraStartAttempt.PERMISSION_MISSING
        if (securityException || errorClassName.endsWith("ForegroundServiceStartNotAllowedException")) {
            return CameraStartAttempt.BACKGROUND_RESTRICTED
        }
        return CameraStartAttempt.FAILED
    }
}

internal enum class CameraCapturePhase {
    STARTING,
    AWAITING_USER_CONFIRMATION,
    STREAMING,
    STOPPED,
    FAILED,
}

internal data class CameraCaptureStatus(
    val requestId: String,
    val phase: CameraCapturePhase,
    val reasonCode: String = "",
    val retryable: Boolean = false,
)

internal object CameraCaptureStatusBus {
    private val mutableStatus = MutableStateFlow(
        CameraCaptureStatus(requestId = "", phase = CameraCapturePhase.STOPPED),
    )
    val statuses = mutableStatus.asStateFlow()

    fun publish(status: CameraCaptureStatus) {
        mutableStatus.value = status
    }
}

internal interface CameraStartGateway {
    fun tryStart(request: CameraCaptureRequest): CameraStartAttempt
    fun requestUserConfirmation(request: CameraCaptureRequest): Boolean
    fun stop(request: CameraCaptureRequest)
}

internal class CameraStartCoordinator(private val gateway: CameraStartGateway) {
    fun apply(request: CameraCaptureRequest): CameraCaptureStatus {
        val status = if (!request.enabled) {
            gateway.stop(request)
            CameraCaptureStatus(request.requestId, CameraCapturePhase.STOPPED)
        } else {
            when (gateway.tryStart(request)) {
                CameraStartAttempt.ACCEPTED ->
                    CameraCaptureStatus(request.requestId, CameraCapturePhase.STARTING)
                CameraStartAttempt.BACKGROUND_RESTRICTED -> if (gateway.requestUserConfirmation(request)) {
                    CameraCaptureStatus(
                        request.requestId,
                        CameraCapturePhase.AWAITING_USER_CONFIRMATION,
                        reasonCode = "camera_confirmation_required",
                        retryable = true,
                    )
                } else {
                    CameraCaptureStatus(
                        request.requestId,
                        CameraCapturePhase.FAILED,
                        reasonCode = "camera_confirmation_unavailable",
                        retryable = true,
                    )
                }
                CameraStartAttempt.PERMISSION_MISSING -> CameraCaptureStatus(
                    request.requestId,
                    CameraCapturePhase.FAILED,
                    reasonCode = "camera_permission_required",
                )
                CameraStartAttempt.FAILED -> CameraCaptureStatus(
                    request.requestId,
                    CameraCapturePhase.FAILED,
                    reasonCode = "camera_start_failed",
                    retryable = true,
                )
            }
        }
        CameraCaptureStatusBus.publish(status)
        return status
    }
}
