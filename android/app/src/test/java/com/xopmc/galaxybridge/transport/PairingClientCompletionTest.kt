package com.xopmc.galaxybridge.transport

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingClientCompletionTest {
    @Test
    fun eofIsSuccessfulOnlyAfterCommitAcknowledgementWasSent() {
        assertFalse(pairingEOFCompletes(isCommitted = false, acknowledgementSentAtMillis = 0))
        assertFalse(pairingEOFCompletes(isCommitted = true, acknowledgementSentAtMillis = 0))
        assertFalse(pairingEOFCompletes(isCommitted = false, acknowledgementSentAtMillis = 1))
        assertTrue(pairingEOFCompletes(isCommitted = true, acknowledgementSentAtMillis = 1))
    }
}
