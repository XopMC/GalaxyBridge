package com.xopmc.galaxybridge.transport.shell

import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/** DUMP prepares admission; only a direct shell Binder caller may consume it.
 * A consumed claim fences one activation until replacement/revocation, not a
 * generic capability that can be reconstructed from matching metadata. */
internal class ShellActivationTicketPolicy {
    class Claim internal constructor(val revision: Long)
    private class Ticket(val activation: String, val token: ByteArray, val boot: String, val preparedAt: Long)
    private var ticket: Ticket? = null
    private var revision = 0L
    private var activeClaim: Claim? = null
    @Synchronized fun prepare(activationID: String, token: String, bootGeneration: String, nowMillis: Long,
        foreground: Boolean, distributionAllowed: Boolean): Long? {
        revoke()
        if (!foreground || !distributionAllowed || nowMillis < 0 ||
            !ShellBridgePolicy.activation(activationID, token, bootGeneration)) return null
        ticket = Ticket(activationID, token.toByteArray(StandardCharsets.US_ASCII), bootGeneration, nowMillis)
        return revision
    }
    @Synchronized fun consume(callerUID: Int, activationID: String, token: String, bootGeneration: String, nowMillis: Long,
        foreground: Boolean, distributionAllowed: Boolean): Claim? {
        // Provider must perform this same check BEFORE reading its Bundle.
        // An unauthorized caller must not even invalidate a genuine ticket.
        if (!admitsCaller(callerUID)) return null
        if (!foreground || !distributionAllowed) { revoke(); return null }
        val prepared = ticket ?: return null
        if (nowMillis < prepared.preparedAt || nowMillis - prepared.preparedAt >= TICKET_MILLIS) {
            revoke(); return null
        }
        if (prepared.activation != activationID || prepared.boot != bootGeneration ||
            !ShellBridgePolicy.activation(activationID, token, bootGeneration) ||
            !MessageDigest.isEqual(prepared.token, token.toByteArray(StandardCharsets.US_ASCII))) return null
        prepared.token.fill(0)
        ticket = null
        return Claim(revision).also { activeClaim = it }
    }
    @Synchronized fun isCurrent(claim: Claim): Boolean = activeClaim === claim && claim.revision == revision
    @Synchronized fun revoke() {
        ticket?.token?.fill(0)
        ticket = null; activeClaim = null; revision++
    }
    companion object {
        private const val TICKET_MILLIS = 10_000L
        fun admitsCaller(callerUID: Int): Boolean = callerUID == 2000
    }
}
