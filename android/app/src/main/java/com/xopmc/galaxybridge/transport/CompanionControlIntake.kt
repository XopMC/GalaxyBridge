package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.Pong
import java.io.IOException

/** Used only after the authenticated socket has claimed the CONTROL role. */
internal class CompanionControlIntake(
    private val deviceID: String,
    private val authorized: () -> Boolean,
    featureAllowed: (Envelope) -> Boolean = { true },
    featureRejected: (Envelope) -> Unit = { throw IOException("feature_disabled") },
    dispatch: (Envelope) -> Unit,
    renew: () -> Unit,
    writeFrame: (ByteArray) -> Unit,
    failed: (Exception) -> Unit,
) {
    private val failure: (Exception) -> Unit = { error -> closeAdmission(); failed(error) }
    private val operations = CompanionControlQueue<Envelope>("operations", authorized = authorized, dispatch = {
        if (featureAllowed(it)) dispatch(it) else featureRejected(it)
    }, failed = failure)
    private val writer = CompanionControlQueue("writer", authorized = authorized, dispatch = writeFrame, failed = failure)
    // At most one running renewal; duplicate heartbeat renewals are coalesced.
    // The gateway only renews existing peer/session leases, never recreates one.
    private val renewal = CompanionControlQueue<Unit>("renewal", maxItems = 1,
        authorized = authorized, dispatch = { renew() }, failed = failure)

    fun admit(request: Envelope): Boolean {
        if (!authorized() || request.hasOpenChannel()) return false
        if (!request.hasPing()) return operations.offer(request, request.serializedSize)
        val response = Envelope.newBuilder().setProtocolMajor(1).setDeviceId(deviceID)
            .setSessionId(request.sessionId).setMessageId(request.messageId + 1)
            .setPong(Pong.newBuilder().setEchoedMonotonicTimeNs(request.ping.monotonicTimeNs)).build()
        if (!writer.offer(response.toByteArray(), response.serializedSize, priority = true)) return false
        renewal.offer(Unit, 0)
        return true
    }

    fun reply(response: Envelope) {
        if (!writer.offer(response.toByteArray(), response.serializedSize, priority = response.hasPong()))
            throw IOException("control_response_queue_closed_or_full")
    }

    fun closeAdmission() {
        operations.closeAdmission(); writer.closeAdmission(); renewal.closeAdmission()
    }

    /** Caller first closes the socket, unblocking a stalled frame write. */
    fun awaitSettled() {
        operations.awaitSettled(); renewal.awaitSettled(); writer.awaitSettled()
    }
}
