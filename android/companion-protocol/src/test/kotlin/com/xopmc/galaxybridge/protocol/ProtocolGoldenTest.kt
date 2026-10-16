package com.xopmc.galaxybridge.protocol

import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.CameraCaptureState
import com.xopmc.galaxybridge.protocol.v1.CameraStatus
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class ProtocolGoldenTest {
    @Test fun notificationActionResultCorrelatesWithoutChangingLegacyActionBytes() {
        val legacy = com.xopmc.galaxybridge.protocol.v1.NotificationAction.newBuilder()
            .setNotificationId("synthetic").setActionId("0").setReplyText("Galaxy Bridge QA — ответ42").build()
        assertEquals("", com.xopmc.galaxybridge.protocol.v1.NotificationAction.parseFrom(legacy.toByteArray()).requestId)
        val request = legacy.toBuilder().setRequestId("69830b65-6352-4b3a-8a21-70bcda45787e").build()
        assertEquals(request, com.xopmc.galaxybridge.protocol.v1.NotificationAction.parseFrom(request.toByteArray()))
        val result = com.xopmc.galaxybridge.protocol.v1.NotificationActionResult.newBuilder()
            .setRequestId(request.requestId).setNotificationId(request.notificationId).setActionId(request.actionId)
            .setAccepted(false).setErrorCode("pending_intent_canceled").build()
        val envelope = Envelope.newBuilder().setProtocolMajor(1).setNotificationActionResult(result).build()
        assertEquals(result, Envelope.parseFrom(envelope.toByteArray()).notificationActionResult)
        assertEquals(13, com.xopmc.galaxybridge.protocol.v1.Capability.CAPABILITY_NOTIFICATION_ACTION_RESULTS.number)
    }
    @Test
    fun envelopeRoundTripsCanonicalFixture() {
        val fixture = javaClass.classLoader
            ?.getResourceAsStream("envelope_v1.hex")
        assertNotNull("missing canonical protocol fixture", fixture)

        val encoded = fixture!!.bufferedReader().use { reader ->
            reader.readText().trim().chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }
        val envelope = Envelope.parseFrom(encoded)

        assertEquals(1, envelope.protocolMajor)
        assertEquals(42L, envelope.messageId)
        assertArrayEquals(encoded, envelope.toByteArray())
    }

    @Test
    fun cameraStatusCarriesRequestCorrelationAndExplicitPendingState() {
        val encoded = Envelope.newBuilder()
            .setProtocolMajor(1)
            .setProtocolMinor(1)
            .setCameraStatus(
                CameraStatus.newBuilder()
                    .setRequestId("camera-request-1")
                    .setState(CameraCaptureState.CAMERA_CAPTURE_STATE_AWAITING_USER_CONFIRMATION)
                    .setReasonCode("camera_confirmation_required")
                    .setRetryable(true),
            )
            .build()
            .toByteArray()

        val decoded = Envelope.parseFrom(encoded).cameraStatus

        assertEquals("camera-request-1", decoded.requestId)
        assertEquals(CameraCaptureState.CAMERA_CAPTURE_STATE_AWAITING_USER_CONFIRMATION, decoded.state)
        assertEquals("camera_confirmation_required", decoded.reasonCode)
        assertEquals(true, decoded.retryable)
    }
}
