package com.xopmc.galaxybridge.service

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraCaptureStatusBusTest {
    @Test
    fun aLateEventsChannelReceivesTheLatestCameraState() = runBlocking {
        val expected = CameraCaptureStatus(
            requestId = "replay-request",
            phase = CameraCapturePhase.AWAITING_USER_CONFIRMATION,
            reasonCode = "camera_confirmation_required",
            retryable = true,
        )
        CameraCaptureStatusBus.publish(expected)

        val received = withTimeout(500) { CameraCaptureStatusBus.statuses.first() }

        assertEquals(expected, received)
    }
}
