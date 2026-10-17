package com.xopmc.galaxybridge.nearby

import org.junit.Assert.*
import org.junit.Test

private class BluetoothAdapter(var isEnabled: Boolean = false) {
    companion object { const val ACTION_REQUEST_ENABLE = "android.bluetooth.adapter.action.REQUEST_ENABLE" }
}
private class BluetoothManager { var adapter: BluetoothAdapter? = BluetoothAdapter() }
private class Intent(val action: String, @Suppress("UNUSED_PARAMETER") uri: Any? = null)
private object Settings { const val ACTION_APPLICATION_DETAILS_SETTINGS = "settings" }
private object Uri { @Suppress("UNUSED_PARAMETER") fun fromParts(a: String, b: String, c: Any?) = Any() }
private object Manifest { object permission { const val ACCESS_LOCAL_NETWORK = "local-network" } }
private object PackageManager { const val PERMISSION_GRANTED = 0 }
private object ContextCompat { @Suppress("UNUSED_PARAMETER") fun checkSelfPermission(a: Any, permission: String) = 0 }
private object R { object string { const val setup_action_unavailable = 1; const val nearby_permission_required = 2 } }
private enum class SetupAction { NearbyDevicesPermission, LocalNetworkPermission }
private enum class PermissionRoute { None, Settings, Request }
private class PermissionGate(var inFlight: SetupAction? = null) {
    fun begin(action: SetupAction) = PermissionGate(action)
    fun complete() = PermissionGate()
}
private data class Setup(val completed: Boolean = false) { @Suppress("UNUSED_PARAMETER") fun attempted(action: SetupAction) = this }
private class Preferences {
    var paired = false
    var nearbyEnabled = true
    var bluetoothRequested = false
    @Suppress("UNUSED_PARAMETER") fun edit(commit: Boolean = false, action: Preferences.() -> Unit) = action()
    fun putBoolean(key: String, value: Boolean) { if (key == "bluetooth_enable_requested_v1") bluetoothRequested = value }
    @Suppress("UNUSED_PARAMETER") fun getString(key: String, fallback: String?): String? = if (paired) "existing-host" else fallback
    @Suppress("UNUSED_PARAMETER") fun getBoolean(key: String, fallback: Boolean) =
        if (key == "bluetooth_enable_requested_v1") bluetoothRequested else nearbyEnabled
}
private class PermissionLauncher { var launches = 0; @Suppress("UNUSED_PARAMETER") fun launch(permissions: Array<String>) { launches++ } }
private class BluetoothLauncher { val actions = mutableListOf<String>(); fun launch(intent: Intent) { actions += intent.action } }
private class PendingEnable {
    var requested = false
    fun request() { requested = true }
    fun cancel() { requested = false }
}
private object ForegroundConnectivityRuntime { fun hasNearbyPermissions(activity: EnableActivity) = activity.permissions }
private class EnableActivity {
    val bluetooth = BluetoothManager()
    var bluetoothEnableInFlight = false
    val bluetoothEnableLauncher = BluetoothLauncher()
    val nearbyPermissionLauncher = PermissionLauncher()
    var pendingNearbyEnable = PendingEnable()
    var runtimePermissionGate = PermissionGate()
    var automaticSetup = Setup()
    var route = PermissionRoute.None
    var permissions = true
    var setupActionError: String? = null
    var refreshToken = 0
    var deliveries = 0
    var serviceRefreshes = 0
    var completedBeforePrompt = false
    val preferences = Preferences()
    val packageName = "fixture"
    val PREFERENCES = "fixture"
    val MODE_PRIVATE = 0
    val BLUETOOTH_ENABLE_REQUESTED = "bluetooth_enable_requested_v1"
    @Suppress("UNCHECKED_CAST", "UNUSED_PARAMETER") fun <T> getSystemService(kind: Class<T>) = bluetooth as? T
    @Suppress("UNUSED_PARAMETER") fun getString(resource: Int) = "unavailable"
    @Suppress("UNUSED_PARAMETER") fun nearbyPermissionRoute(explicitRequest: Boolean) = route
    fun nearbyPermissions() = listOf("connect", "advertise", "nearby")
    fun saveAutomaticSetup() { completedBeforePrompt = automaticSetup.completed }
    @Suppress("UNUSED_PARAMETER") fun getSharedPreferences(name: String, mode: Int) = preferences
    @Suppress("UNUSED_PARAMETER") fun startActivity(intent: Intent) {}
    fun startBridgeServiceIfAllowed() { serviceRefreshes++ }
    fun enableNearbyAndDeliverOffer() { if (pendingNearbyEnable.requested) { deliveries++; pendingNearbyEnable.cancel() } }
    // ACTUAL_REQUEST_NEARBY
    // ACTUAL_CONTINUE_NEARBY
    // ACTUAL_RADIO_STATE
    // ACTUAL_REQUEST_BLUETOOTH
    // ACTUAL_COMPLETE_BLUETOOTH
    // ACTUAL_FINISH_SETUP
}

class NearbyBluetoothEnableSpec {
    @Test fun firstJourneyPromptsOnlyOnceAndNeverOnPairedOrCompletedUpgrade() {
        val fresh = EnableActivity()
        fresh.finishAutomaticSetup()
        assertTrue(fresh.completedBeforePrompt)
        assertEquals(1, fresh.bluetoothEnableLauncher.actions.size)
        fresh.completeBluetoothEnable()
        fresh.finishAutomaticSetup()
        assertEquals(1, fresh.bluetoothEnableLauncher.actions.size)
        for (activity in listOf(EnableActivity().also { it.preferences.paired = true },
            EnableActivity().also { it.automaticSetup = Setup(completed = true) },
            EnableActivity().also { it.permissions = false }, EnableActivity().also { it.preferences.nearbyEnabled = false })) {
            activity.finishAutomaticSetup()
            assertTrue(activity.bluetoothEnableLauncher.actions.isEmpty())
        }
    }
    @Test fun explicitRequestUsesAndroidDialogBeforeCompletingNearbyEnable() {
        val activity = EnableActivity()
        activity.requestNearbyEnable()
        assertEquals(listOf(BluetoothAdapter.ACTION_REQUEST_ENABLE), activity.bluetoothEnableLauncher.actions)
        assertTrue(activity.bluetoothEnableInFlight)
        assertTrue(activity.pendingNearbyEnable.requested)
        assertEquals(0, activity.deliveries)
        repeat(3) { activity.continueNearbyEnable(explicitRequest = true) }
        assertEquals(1, activity.bluetoothEnableLauncher.actions.size)
    }

    @Test fun cancellationNeverRepromptsFromResumeAndExplicitRetryRemainsAvailable() {
        val activity = EnableActivity()
        activity.requestNearbyEnable()
        activity.completeBluetoothEnable()
        assertFalse(activity.bluetoothEnableInFlight)
        assertFalse(activity.pendingNearbyEnable.requested)
        repeat(4) { activity.continueNearbyEnable(explicitRequest = false) }
        assertEquals(1, activity.bluetoothEnableLauncher.actions.size)
        assertEquals(0, activity.deliveries)
        activity.requestNearbyEnable()
        assertEquals(2, activity.bluetoothEnableLauncher.actions.size)
    }

    @Test fun cancellingAnExplicitRequestDuringSetupDoesNotTriggerAnotherAutomaticDialog() {
        val activity = EnableActivity()
        activity.requestNearbyEnable()
        activity.completeBluetoothEnable()
        activity.finishAutomaticSetup()
        assertEquals(1, activity.bluetoothEnableLauncher.actions.size)
    }

    @Test fun acceptedResultRechecksRealRadioAndResumesExistingPendingAction() {
        val activity = EnableActivity()
        activity.requestNearbyEnable()
        activity.bluetooth.adapter?.isEnabled = true
        activity.completeBluetoothEnable()
        assertFalse(activity.bluetoothEnableInFlight)
        assertEquals(1, activity.deliveries)
        assertTrue(activity.serviceRefreshes > 0)
        val alreadyOn = EnableActivity().also { it.bluetooth.adapter?.isEnabled = true }
        alreadyOn.requestNearbyEnable()
        assertTrue(alreadyOn.bluetoothEnableLauncher.actions.isEmpty())
        assertEquals(1, alreadyOn.deliveries)
    }

    @Test fun passiveResumeAndMissingPermissionNeverOpenRadioDialog() {
        val passive = EnableActivity()
        passive.pendingNearbyEnable.request()
        passive.continueNearbyEnable(explicitRequest = false)
        assertTrue(passive.bluetoothEnableLauncher.actions.isEmpty())
        assertEquals(0, passive.deliveries)
        val denied = EnableActivity().also { it.permissions = false }
        denied.requestNearbyEnable()
        assertTrue(denied.bluetoothEnableLauncher.actions.isEmpty())
        val permissionInFlight = EnableActivity().also { it.runtimePermissionGate = PermissionGate(SetupAction.NearbyDevicesPermission) }
        permissionInFlight.requestNearbyEnable()
        assertTrue(permissionInFlight.bluetoothEnableLauncher.actions.isEmpty())
    }
}
