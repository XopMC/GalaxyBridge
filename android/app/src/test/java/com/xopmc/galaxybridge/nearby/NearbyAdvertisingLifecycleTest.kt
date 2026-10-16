package com.xopmc.galaxybridge.nearby

import org.junit.Assert.*
import org.junit.Test

class NearbyAdvertisingLifecycleTest {
    @Test fun unavailableBluetoothAllowsTheNextRefreshToRetry() {
        val lifecycle = NearbyAdvertisingLifecycle()
        assertFalse(lifecycle.begin(available = false))
        assertFalse("Unavailable Bluetooth must not leave a start in flight", lifecycle.isRunningRequested)
        assertTrue(lifecycle.begin(available = true))
        assertTrue(lifecycle.isRunningRequested)
    }

    @Test fun stoppingReleasesTheStartRequest() {
        val lifecycle = NearbyAdvertisingLifecycle()
        assertTrue(lifecycle.begin(available = true))
        lifecycle.stop()
        assertFalse(lifecycle.isRunningRequested)
    }
}
