package com.xopmc.galaxybridge.service

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PendingPairingRunnerTest {
    @Test
    fun transientFailureRetriesTheSamePendingPairingUntilItSucceeds() = runBlocking {
        var nowMillis = 0L
        var pending: String? = PENDING_FIXTURE
        var attempts = 0
        val waits = mutableListOf<Long>()
        val runner = PendingPairingRunner(
            attempt = {
                attempts++
                (attempts == 2).also { success -> if (success) pending = null }
            },
            currentPending = { pending },
            expiresAtMillis = { _, _ -> 120_000L },
            nowMillis = { nowMillis },
            wait = { duration -> waits += duration; nowMillis += duration },
            clearPendingIfCurrent = { if (pending == it) pending = null },
        )

        runner.run(PENDING_FIXTURE)

        assertEquals(2, attempts)
        assertEquals(listOf(1_000L), waits)
        assertNull(pending)
    }

    @Test
    fun retryThatWouldCrossExpiryClearsTheStalePendingPairing() = runBlocking {
        var nowMillis = 0L
        var pending: String? = PENDING_FIXTURE
        var attempts = 0
        val waits = mutableListOf<Long>()
        val runner = PendingPairingRunner(
            attempt = { attempts++; false },
            currentPending = { pending },
            expiresAtMillis = { _, _ -> 2_500L },
            nowMillis = { nowMillis },
            wait = { duration -> waits += duration; nowMillis += duration },
            clearPendingIfCurrent = { if (pending == it) pending = null },
        )

        runner.run(PENDING_FIXTURE)

        assertEquals(2, attempts)
        assertEquals(listOf(1_000L), waits)
        assertNull(pending)
    }

    @Test
    fun invalidPendingPairingIsClearedWithoutOpeningANetworkConnection() = runBlocking {
        var pending: String? = PENDING_FIXTURE
        var attempts = 0
        val runner = PendingPairingRunner(
            attempt = { attempts++; false },
            currentPending = { pending },
            expiresAtMillis = { _, _ -> error("invalid pairing") },
            nowMillis = { 0L },
            wait = {},
            clearPendingIfCurrent = { if (pending == it) pending = null },
        )

        runner.run(PENDING_FIXTURE)

        assertEquals(0, attempts)
        assertNull(pending)
    }

    private companion object {
        const val PENDING_FIXTURE = "redacted-pending-pairing"
    }
}
