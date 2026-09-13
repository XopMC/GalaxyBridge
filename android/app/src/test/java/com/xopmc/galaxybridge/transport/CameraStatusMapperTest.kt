package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.CameraCaptureState
import com.xopmc.galaxybridge.service.CameraCapturePhase
import com.xopmc.galaxybridge.service.CameraCaptureStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraStatusMapperTest {
    @Test
    fun pendingConfirmationMapsToTheStableProtocolState() {
        val mapped = CameraStatusMapper.toProtocol(
            CameraCaptureStatus(
                requestId = "camera-request-1",
                phase = CameraCapturePhase.AWAITING_USER_CONFIRMATION,
                reasonCode = "camera_confirmation_required",
                retryable = true,
            ),
        )

        assertEquals("camera-request-1", mapped.requestId)
        assertEquals(CameraCaptureState.CAMERA_CAPTURE_STATE_AWAITING_USER_CONFIRMATION, mapped.state)
        assertEquals("camera_confirmation_required", mapped.reasonCode)
        assertTrue(mapped.retryable)
    }

    @Test
    fun everyInternalPhaseHasAnExplicitProtocolValue() {
        val expected = mapOf(
            CameraCapturePhase.STARTING to CameraCaptureState.CAMERA_CAPTURE_STATE_STARTING,
            CameraCapturePhase.AWAITING_USER_CONFIRMATION to CameraCaptureState.CAMERA_CAPTURE_STATE_AWAITING_USER_CONFIRMATION,
            CameraCapturePhase.STREAMING to CameraCaptureState.CAMERA_CAPTURE_STATE_STREAMING,
            CameraCapturePhase.STOPPED to CameraCaptureState.CAMERA_CAPTURE_STATE_STOPPED,
            CameraCapturePhase.FAILED to CameraCaptureState.CAMERA_CAPTURE_STATE_FAILED,
        )

        expected.forEach { (phase, protocolState) ->
            val mapped = CameraStatusMapper.toProtocol(CameraCaptureStatus("request", phase))
            assertEquals(protocolState, mapped.state)
        }
    }
}
