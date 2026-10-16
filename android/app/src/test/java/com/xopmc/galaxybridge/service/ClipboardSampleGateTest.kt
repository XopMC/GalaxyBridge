package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSampleGateTest {
    @Test fun slowImageCannotOverwriteNewerTextOrSensitiveClipboard() {
        val gate = ClipboardSampleGate()
        val delivered = mutableListOf<String>()
        val image = gate.beginSample()
        val text = gate.beginSample()
        assertTrue(gate.publishIfCurrent(text) { delivered += "new text" })
        assertFalse(gate.publishIfCurrent(image) { delivered += "old image" })
        val secondImage = gate.beginSample()
        gate.beginSample() // A sensitive/unsupported clip invalidates pending work too.
        assertFalse(gate.publishIfCurrent(secondImage) { delivered += "stale image" })
        assertEquals(listOf("new text"), delivered)
    }

    @Test fun focusLossOrCloseInvalidatesAnInFlightImage() {
        val gate = ClipboardSampleGate()
        val image = gate.beginSample()
        gate.invalidate()
        assertFalse(gate.publishIfCurrent(image) { error("Retired sample published") })
        val next = gate.beginSample()
        assertTrue(gate.publishIfCurrent(next) {})
    }
}
