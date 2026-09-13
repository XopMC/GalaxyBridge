package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.Envelope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionAuthenticationRejectionResponseTest {
    @Test
    fun missingPairingGetsAStableNonRetryableRecoveryCode() {
        val response = SessionAuthenticationRejectionResponse.make(
            request = request(),
            deviceId = "phone-id",
            failure = SessionAuthenticationFailure.MISSING_PAIRING,
        )

        assertEquals(1, response.protocolMajor)
        assertEquals("phone-id", response.deviceId)
        assertEquals("session-id", response.sessionId)
        assertEquals(42, response.messageId)
        assertTrue(response.hasError())
        assertEquals(SessionAuthenticationRejectionResponse.PAIRING_REQUIRED, response.error.code)
        assertEquals("", response.error.safeMessage)
        assertFalse(response.error.retryable)
    }

    @Test
    fun invalidProofDoesNotExposeTheSpecificValidationFailure() {
        val publicFailures = listOf(
            SessionAuthenticationFailure.MALFORMED,
            SessionAuthenticationFailure.HOST_ID,
            SessionAuthenticationFailure.PUBLIC_KEY,
            SessionAuthenticationFailure.TIMESTAMP,
            SessionAuthenticationFailure.SIGNATURE,
        )

        publicFailures.forEach { failure ->
            val response = SessionAuthenticationRejectionResponse.make(request(), "phone-id", failure)
            assertEquals(SessionAuthenticationRejectionResponse.AUTHENTICATION_FAILED, response.error.code)
            assertEquals("", response.error.safeMessage)
            assertFalse(response.error.retryable)
        }
    }

    private fun request(): Envelope = Envelope.newBuilder()
        .setDeviceId("mac-id")
        .setSessionId("session-id")
        .setMessageId(41)
        .build()
}
