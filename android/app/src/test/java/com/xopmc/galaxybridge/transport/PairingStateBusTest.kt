package com.xopmc.galaxybridge.transport

import org.junit.Assert.assertEquals
import org.junit.Test

class PairingStateBusTest {
    @Test
    fun successfulPairingAdvancesObservableRevision() {
        val before = PairingStateBus.revision.value

        PairingStateBus.publishSuccess()

        assertEquals(before + 1, PairingStateBus.revision.value)
    }
}
