package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.core.PairingTranscript
import com.xopmc.galaxybridge.core.SessionAuthenticationTranscript
import com.xopmc.galaxybridge.protocol.v1.Envelope
import java.security.MessageDigest
import kotlin.math.abs

internal enum class SessionAuthenticationFailure {
    MISSING_PAIRING,
    MALFORMED,
    HOST_ID,
    PUBLIC_KEY,
    TIMESTAMP,
    SIGNATURE,
}

/** Content-free failure codes keep LAN diagnostics useful without logging trust material. */
internal object SessionAuthenticationValidator {
    private const val MAX_CLOCK_SKEW_SECONDS = 120L

    fun failure(
        envelope: Envelope,
        pairedHostId: String?,
        storedPublicKey: ByteArray?,
        nowUnixSeconds: Long,
    ): SessionAuthenticationFailure? {
        if (pairedHostId.isNullOrBlank() || storedPublicKey == null) {
            return SessionAuthenticationFailure.MISSING_PAIRING
        }
        if (!envelope.hasSessionAuthentication()) return SessionAuthenticationFailure.MALFORMED

        val authentication = envelope.sessionAuthentication
        val key = authentication.identityPublicKey.toByteArray()
        val nonce = authentication.nonce.toByteArray()
        if (envelope.deviceId != pairedHostId) return SessionAuthenticationFailure.HOST_ID
        if (envelope.sessionId.isBlank() || envelope.sessionId.length > 128 || key.size != 65 || nonce.size != 32) {
            return SessionAuthenticationFailure.MALFORMED
        }
        if (!MessageDigest.isEqual(key, storedPublicKey)) return SessionAuthenticationFailure.PUBLIC_KEY
        if (abs(nowUnixSeconds - authentication.timestampUnixSeconds) > MAX_CLOCK_SKEW_SECONDS) {
            return SessionAuthenticationFailure.TIMESTAMP
        }
        val transcript = SessionAuthenticationTranscript.make(
            envelope.deviceId,
            envelope.sessionId,
            nonce,
            authentication.timestampUnixSeconds,
            key,
        )
        if (!PairingTranscript.verify(authentication.signature.toByteArray(), transcript, key)) {
            return SessionAuthenticationFailure.SIGNATURE
        }
        return null
    }
}
