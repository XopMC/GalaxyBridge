package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.protocol.v1.CallEvent
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.InputEvent
import com.xopmc.galaxybridge.protocol.v1.TransferCancel
import com.xopmc.galaxybridge.protocol.v1.SmsEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompanionControlPayloadPolicyTest {
    @Test fun featurePolicyIsAnAdditiveControlPayloadWithAnExplicitAllOffList() {
        val request = Envelope.newBuilder().setFeatureConfigurationRequest(
            com.xopmc.galaxybridge.protocol.v1.FeatureConfigurationRequest.newBuilder()
                .setRequestId("c6ae882b-f502-46f0-a40d-44b8e207e022").setTargetDeviceId("phone").setRevision(9),
        ).build()
        val decoded = Envelope.parseFrom(request.toByteArray())
        assertEquals(44, decoded.payloadCase.number)
        assertTrue(decoded.featureConfigurationRequest.enabledFeatureIdsList.isEmpty())
        assertEquals(CompanionControlPayloadKind.FEATURE_CONFIGURATION, CompanionControlPayloadPolicy.classify(decoded))
        val receipt = Envelope.newBuilder().setFeatureConfigurationResult(
            com.xopmc.galaxybridge.protocol.v1.FeatureConfigurationResult.newBuilder().setAccepted(true).setRevision(9),
        ).build()
        assertEquals(45, Envelope.parseFrom(receipt.toByteArray()).payloadCase.number)
        assertEquals(17, com.xopmc.galaxybridge.protocol.v1.Capability.CAPABILITY_FEATURE_CONFIGURATION.number)
    }

    @Test
    fun transferCancelUsesAdditiveWireTagAndRoutesToFileReceiver() {
        val request = Envelope.newBuilder().setTransferCancel(
            TransferCancel.newBuilder().setTransferId("owned-transfer"),
        ).build()
        val decoded = Envelope.parseFrom(request.toByteArray())
        assertEquals(34, decoded.payloadCase.number)
        assertEquals("owned-transfer", decoded.transferCancel.transferId)
        assertEquals(CompanionControlPayloadKind.TRANSFER_CANCEL, CompanionControlPayloadPolicy.classify(decoded))
    }

    @Test
    fun callControlIsRoutableOnlyInTelephonyEnabledDistributions() {
        val request = Envelope.newBuilder()
            .setCallEvent(CallEvent.newBuilder().setCallId("call-1"))
            .build()

        val expected = if (BuildConfig.DISTRIBUTION in setOf("internal", "direct")) {
            CompanionControlPayloadKind.CALL
        } else {
            CompanionControlPayloadKind.UNSUPPORTED
        }

        assertEquals(expected, CompanionControlPayloadPolicy.classify(request))
    }

    @Test
    fun directSmsReturnsNonRetryableNotificationActionError() {
        val request = Envelope.newBuilder()
            .setProtocolMajor(1)
            .setProtocolMinor(0)
            .setDeviceId("mac-device")
            .setSessionId("session-7")
            .setMessageId(41)
            .setSmsEvent(
                SmsEvent.newBuilder()
                    .setMessageId("sms-1")
                    .setAddress("+10000000000")
                    .setBody("must not be sent"),
            )
            .build()

        assertEquals(CompanionControlPayloadKind.UNSUPPORTED, CompanionControlPayloadPolicy.classify(request))
        val response = CompanionControlPayloadPolicy.unsupportedResponse(request, "phone-device")

        assertTrue(response.hasError())
        assertEquals("sms_notification_actions_only", response.error.code)
        assertEquals("Reply through a message notification action.", response.error.safeMessage)
        assertFalse(response.error.retryable)
        assertEquals("phone-device", response.deviceId)
        assertEquals("session-7", response.sessionId)
        assertEquals(42, response.messageId)
    }

    @Test
    fun supportedInputIsClassifiedWithoutProducingAnError() {
        val request = Envelope.newBuilder()
            .setInputEvent(InputEvent.newBuilder().setText("hello"))
            .build()

        assertEquals(CompanionControlPayloadKind.INPUT, CompanionControlPayloadPolicy.classify(request))
    }

    @Test
    fun protocolPayloadNotAcceptedByThePhoneReturnsGenericSafeError() {
        val request = Envelope.newBuilder()
            .setProtocolMajor(1)
            .setSessionId("session-8")
            .setMessageId(9)
            .build()

        val response = CompanionControlPayloadPolicy.unsupportedResponse(request, "phone-device")

        assertEquals("unsupported_payload", response.error.code)
        assertEquals("This request is not supported by Galaxy Bridge on this phone.", response.error.safeMessage)
        assertFalse(response.error.retryable)
    }
}
