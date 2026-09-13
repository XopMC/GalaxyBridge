package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.ErrorEvent

/**
 * Returns a content-free authentication result before closing the TLS connection.
 * The Mac has already pinned this phone's certificate, so it can turn the stable
 * code into a localised recovery instruction without guessing from EOF.
 */
internal object SessionAuthenticationRejectionResponse {
    const val PAIRING_REQUIRED = "pairing_required"
    const val AUTHENTICATION_FAILED = "session_authentication_failed"

    fun make(
        request: Envelope,
        deviceId: String,
        failure: SessionAuthenticationFailure,
    ): Envelope = Envelope.newBuilder()
        .setProtocolMajor(1)
        .setProtocolMinor(0)
        .setDeviceId(deviceId)
        .setSessionId(request.sessionId)
        .setMessageId(request.messageId + 1)
        .setError(
            ErrorEvent.newBuilder()
                .setCode(
                    if (failure == SessionAuthenticationFailure.MISSING_PAIRING) {
                        PAIRING_REQUIRED
                    } else {
                        AUTHENTICATION_FAILED
                    },
                )
                .setRetryable(false),
        )
        .build()
}
