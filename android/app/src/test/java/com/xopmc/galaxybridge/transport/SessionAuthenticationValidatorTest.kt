package com.xopmc.galaxybridge.transport

import com.google.protobuf.ByteString
import com.xopmc.galaxybridge.core.P256Keys
import com.xopmc.galaxybridge.core.SessionAuthenticationTranscript
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.SessionAuthentication
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SessionAuthenticationValidatorTest {
    @Test
    fun acceptsCurrentSignedTranscriptAndClassifiesEverySafeFailure() {
        val keys = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }.generateKeyPair()
        val publicKey = P256Keys.x963Representation(keys.public)
        val hostId = "3e501034-8268-4b5a-a348-9f3f941a9aa8"
        val sessionId = "session-1"
        val nonce = ByteArray(32) { 0x41 }
        val now = 1_788_293_000L
        val transcript = SessionAuthenticationTranscript.make(hostId, sessionId, nonce, now, publicKey)
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(keys.private)
            update(transcript)
            sign()
        }
        val valid = envelope(hostId, sessionId, publicKey, nonce, now, signature)

        assertNull(SessionAuthenticationValidator.failure(valid, hostId, publicKey, now))
        assertEquals(
            SessionAuthenticationFailure.HOST_ID,
            SessionAuthenticationValidator.failure(valid, "different-host", publicKey, now),
        )
        assertEquals(
            SessionAuthenticationFailure.PUBLIC_KEY,
            SessionAuthenticationValidator.failure(valid, hostId, publicKey.copyOf().also { it[1] = 0 }, now),
        )
        assertEquals(
            SessionAuthenticationFailure.TIMESTAMP,
            SessionAuthenticationValidator.failure(valid, hostId, publicKey, now + 121),
        )
        assertEquals(
            SessionAuthenticationFailure.SIGNATURE,
            SessionAuthenticationValidator.failure(
                valid.toBuilder().setSessionAuthentication(
                    valid.sessionAuthentication.toBuilder().setSignature(ByteString.copyFrom(byteArrayOf(1, 2, 3))),
                ).build(),
                hostId,
                publicKey,
                now,
            ),
        )
        assertEquals(
            SessionAuthenticationFailure.MALFORMED,
            SessionAuthenticationValidator.failure(Envelope.getDefaultInstance(), hostId, publicKey, now),
        )
    }

    private fun envelope(
        hostId: String,
        sessionId: String,
        publicKey: ByteArray,
        nonce: ByteArray,
        timestamp: Long,
        signature: ByteArray,
    ): Envelope = Envelope.newBuilder()
        .setDeviceId(hostId)
        .setSessionId(sessionId)
        .setSessionAuthentication(
            SessionAuthentication.newBuilder()
                .setIdentityPublicKey(ByteString.copyFrom(publicKey))
                .setNonce(ByteString.copyFrom(nonce))
                .setTimestampUnixSeconds(timestamp)
                .setSignature(ByteString.copyFrom(signature)),
        )
        .build()
}
