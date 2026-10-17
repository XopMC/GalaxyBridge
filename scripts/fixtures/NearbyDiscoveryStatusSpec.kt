package com.xopmc.galaxybridge.nearby

import org.junit.Assert.*
import org.junit.Test

private class StatusAdapter(var isEnabled: Boolean = false)
private class BluetoothManager { var adapter: StatusAdapter? = StatusAdapter() }
private class StatusContext {
    val bluetooth = BluetoothManager()
    @Suppress("UNCHECKED_CAST", "UNUSED_PARAMETER")
    fun <T> getSystemService(kind: Class<T>): T? = bluetooth as? T
}
private class StatusPreferences {
    var enabled = true
    fun getBoolean(key: String, fallback: Boolean) = if (key == "nearby_enabled") enabled else fallback
    @Suppress("UNUSED_PARAMETER") fun getString(key: String, fallback: String?) = fallback
}
private class StatusBLE {
    var isRunningRequested = false
    var starts = 0
    fun start() { starts++; isRunningRequested = true }
    fun close() { isRunningRequested = false }
}
private class StatusCoordinator { var disables = 0; fun disable() { disables++ } }
private class StatusInternet { @Suppress("UNUSED_PARAMETER") fun revokeAllAuthenticated(peer: String) {} }
private class StatusRuntime {
    val context = StatusContext()
    val preferences = StatusPreferences()
    val ble = StatusBLE()
    val coordinator = StatusCoordinator()
    val internet = StatusInternet()
    var advertising = false
    var closed = false
    var permissions = true
    var observingRadio = true
    var latestNearbyError = ""
    fun isOwner() = true
    @Suppress("UNUSED_PARAMETER") fun hasNearbyPermissions(context: StatusContext) = permissions
    fun ensureBluetoothReceiver() = observingRadio
    fun retireBootstrap() { ble.close(); advertising = false }
    fun reportError(it: String) {
        // ACTUAL_DISCOVERY_ERROR_CALLBACK
    }
    fun reportStarted() {
        // ACTUAL_DISCOVERY_STARTED_CALLBACK
    }
    // ACTUAL_DISCOVERY_REFRESH
}

class NearbyDiscoveryStatusSpec {
    @Test fun bluetoothOffIsDistinctAndNeverStartsOrReleasesAnEstablishedLink() {
        val runtime = StatusRuntime()
        runtime.refresh()
        assertEquals("BluetoothOff", NearbyDiscoveryStatusBus.status.value.name)
        assertEquals(0, runtime.ble.starts)
        assertEquals(0, runtime.coordinator.disables)
        runtime.context.bluetooth.adapter?.isEnabled = true
        runtime.refresh()
        assertEquals("Starting", NearbyDiscoveryStatusBus.status.value.name)
        assertEquals(1, runtime.ble.starts)
        runtime.reportStarted()
        assertEquals("Available", NearbyDiscoveryStatusBus.status.value.name)
    }

    @Test fun perPeerRejectionDoesNotPoisonLiveDiscoveryOrMakeRetrySticky() {
        val runtime = StatusRuntime()
        runtime.context.bluetooth.adapter?.isEnabled = true
        runtime.refresh(); runtime.reportStarted()
        for (error in listOf("ble_session_rejected", "ble_bootstrap_rejected", "ble_indication_failed")) {
            runtime.reportError(error)
            assertEquals("A peer error cannot turn off a healthy advertiser", "Available", NearbyDiscoveryStatusBus.status.value.name)
            assertEquals("", runtime.latestNearbyError)
            runtime.refresh()
            assertEquals(1, runtime.ble.starts)
        }
    }

    @Test fun startupAndUnknownFailuresStillReportUnavailable() {
        for (error in listOf("ble_service_failed", "ble_advertise_failed_2", "ble_permission_or_start_failed", "future_error")) {
            val runtime = StatusRuntime()
            runtime.reportStarted(); runtime.reportError(error)
            assertEquals("Unavailable", NearbyDiscoveryStatusBus.status.value.name)
            assertEquals(error, runtime.latestNearbyError)
        }
        val missingPermission = StatusRuntime().also { it.permissions = false }
        missingPermission.refresh()
        assertEquals("Unavailable", NearbyDiscoveryStatusBus.status.value.name)
        assertEquals(1, missingPermission.coordinator.disables)
        val disabled = StatusRuntime().also { it.preferences.enabled = false }
        disabled.refresh()
        assertEquals("Disabled", NearbyDiscoveryStatusBus.status.value.name)
        val noAdapter = StatusRuntime().also { it.context.bluetooth.adapter = null }
        noAdapter.refresh()
        assertEquals("Unavailable", NearbyDiscoveryStatusBus.status.value.name)
        val noMonitor = StatusRuntime().also { it.observingRadio = false }
        noMonitor.refresh()
        assertEquals("Unavailable", NearbyDiscoveryStatusBus.status.value.name)
    }
}
