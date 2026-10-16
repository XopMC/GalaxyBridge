package com.xopmc.galaxybridge.qr

import org.junit.Assert.*
import org.junit.Test

class QrCameraLifecycleTest {
    @Test fun delayedProviderCannotBindAfterScannerDisposal() {
        val lifecycle = QrCameraLifecycle()
        var bindings = 0
        val providerCompleted = { lifecycle.runIfActive { bindings++ } }
        lifecycle.dispose()
        assertFalse(providerCompleted())
        assertEquals(0, bindings)
    }

    @Test fun queuedQrResultCannotPairAfterScannerDisposal() {
        val lifecycle = QrCameraLifecycle()
        var deliveries = 0
        lifecycle.dispose()
        lifecycle.runIfActive { deliveries++ }
        assertEquals(0, deliveries)
    }

    @Test fun liveScannerCanBindAndDeliverResults() {
        val lifecycle = QrCameraLifecycle()
        var actions = 0
        assertTrue(lifecycle.runIfActive { actions++ })
        assertEquals(1, actions)
    }
}
