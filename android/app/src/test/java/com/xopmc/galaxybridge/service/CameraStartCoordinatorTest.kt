package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraStartCoordinatorTest {
    @Test
    fun foregroundStartIsImmediateAndReportsStarting() {
        val gateway = FakeGateway(CameraStartAttempt.ACCEPTED)
        val coordinator = CameraStartCoordinator(gateway)

        val status = coordinator.apply(request())

        assertEquals(CameraCapturePhase.STARTING, status.phase)
        assertEquals("request-1", status.requestId)
        assertEquals(1, gateway.directStarts)
        assertEquals(0, gateway.confirmations)
    }

    @Test
    fun backgroundRestrictionReportsPendingAndPostsAUserConfirmation() {
        val gateway = FakeGateway(CameraStartAttempt.BACKGROUND_RESTRICTED, confirmationPosted = true)
        val coordinator = CameraStartCoordinator(gateway)

        val status = coordinator.apply(request())

        assertEquals(CameraCapturePhase.AWAITING_USER_CONFIRMATION, status.phase)
        assertEquals("camera_confirmation_required", status.reasonCode)
        assertTrue(status.retryable)
        assertEquals(1, gateway.confirmations)
    }

    @Test
    fun unavailableConfirmationIsAnExplicitFailureInsteadOfAFalseSuccess() {
        val gateway = FakeGateway(CameraStartAttempt.BACKGROUND_RESTRICTED, confirmationPosted = false)
        val coordinator = CameraStartCoordinator(gateway)

        val status = coordinator.apply(request())

        assertEquals(CameraCapturePhase.FAILED, status.phase)
        assertEquals("camera_confirmation_unavailable", status.reasonCode)
        assertTrue(status.retryable)
    }

    @Test
    fun missingCameraPermissionIsAnExplicitFailure() {
        val gateway = FakeGateway(CameraStartAttempt.PERMISSION_MISSING)

        val status = CameraStartCoordinator(gateway).apply(request())

        assertEquals(CameraCapturePhase.FAILED, status.phase)
        assertEquals("camera_permission_required", status.reasonCode)
        assertFalse(status.retryable)
    }

    @Test
    fun stopRequestStopsCaptureAndReportsStopped() {
        val gateway = FakeGateway(CameraStartAttempt.ACCEPTED)

        val status = CameraStartCoordinator(gateway).apply(request(enabled = false))

        assertEquals(CameraCapturePhase.STOPPED, status.phase)
        assertEquals(1, gateway.stops)
        assertEquals(0, gateway.directStarts)
    }

    @Test
    fun AndroidForegroundServiceRestrictionIsClassifiedForTheConfirmationPath() {
        assertEquals(
            CameraStartAttempt.BACKGROUND_RESTRICTED,
            CameraStartFailureClassifier.classify(
                cameraPermissionGranted = true,
                errorClassName = "android.app.ForegroundServiceStartNotAllowedException",
                securityException = false,
            ),
        )
        assertEquals(
            CameraStartAttempt.BACKGROUND_RESTRICTED,
            CameraStartFailureClassifier.classify(
                cameraPermissionGranted = true,
                errorClassName = SecurityException::class.java.name,
                securityException = true,
            ),
        )
    }

    @Test
    fun missingPermissionAndUnrelatedRuntimeFailuresStayDistinct() {
        assertEquals(
            CameraStartAttempt.PERMISSION_MISSING,
            CameraStartFailureClassifier.classify(false, RuntimeException::class.java.name, false),
        )
        assertEquals(
            CameraStartAttempt.FAILED,
            CameraStartFailureClassifier.classify(true, RuntimeException::class.java.name, false),
        )
    }

    private fun request(enabled: Boolean = true) = CameraCaptureRequest(
        requestId = "request-1",
        enabled = enabled,
        cameraId = "back",
        width = 1_920,
        height = 1_080,
        framesPerSecond = 30,
    )

    private class FakeGateway(
        private val attempt: CameraStartAttempt,
        private val confirmationPosted: Boolean = false,
    ) : CameraStartGateway {
        var directStarts = 0
        var confirmations = 0
        var stops = 0

        override fun tryStart(request: CameraCaptureRequest): CameraStartAttempt {
            directStarts += 1
            return attempt
        }

        override fun requestUserConfirmation(request: CameraCaptureRequest): Boolean {
            confirmations += 1
            return confirmationPosted
        }

        override fun stop(request: CameraCaptureRequest) {
            stops += 1
        }
    }
}
