package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class ForegroundClipboardGateTest {
    @Test
    fun observesOnlyWhileStartedAndFocusedAndSamplesEachFocusGainOnce() {
        val gate = ForegroundClipboardGate()

        assertEquals(ClipboardMonitorTransition.NONE, gate.onWindowFocusChanged(true))
        assertEquals(ClipboardMonitorTransition.ACTIVATE_AND_SAMPLE, gate.onStarted())
        assertEquals(ClipboardMonitorTransition.NONE, gate.onWindowFocusChanged(true))
        assertEquals(ClipboardMonitorTransition.DEACTIVATE, gate.onWindowFocusChanged(false))
        assertEquals(ClipboardMonitorTransition.ACTIVATE_AND_SAMPLE, gate.onWindowFocusChanged(true))
        assertEquals(ClipboardMonitorTransition.DEACTIVATE, gate.onStopped())
        assertEquals(ClipboardMonitorTransition.NONE, gate.onWindowFocusChanged(false))
    }
}
