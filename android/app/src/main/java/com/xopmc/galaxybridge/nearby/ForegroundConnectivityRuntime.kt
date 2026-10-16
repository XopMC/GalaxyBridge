package com.xopmc.galaxybridge.nearby

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.xopmc.galaxybridge.internet.InternetGatewayRuntime
import com.xopmc.galaxybridge.transport.NearbyBootstrapCoordinator

/** Process-local owner, installed only after Service.startForeground(connectedDevice). */
class ForegroundConnectivityRuntime(private val context: Context, private val isOwner: () -> Boolean,
    companionPort: () -> Int) : AutoCloseable {
    val shell = com.xopmc.galaxybridge.transport.shell.ShellBridgeRuntime(context, isOwner)
    val coordinator = NearbyBootstrapCoordinator(context, isOwner, companionPort)
    val internet = InternetGatewayRuntime(context, isOwner) { }
    private val ble = NearbyBlePeripheral(context, isOwner, coordinator::newSession) { latestNearbyError = it }
    @Volatile var latestNearbyError: String = ""
        private set
    private val preferences = context.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    private var advertising = false
    fun start() { internet.start(); refresh() }
    fun refresh() {
        val enabled = preferences.getBoolean("nearby_enabled", false)
        if (enabled && hasNearbyPermissions(context) && (!advertising || !ble.isRunningRequested)) { ble.start(); advertising = true }
        if ((!enabled || !hasNearbyPermissions(context)) && advertising) { ble.close(); advertising = false; coordinator.disable() }
        if (!preferences.getBoolean("internet_sharing_allowed", false)) {
            val peer = preferences.getString("paired_host_id", null)
            // All leases are individually session-fenced; revokeAll is needed for the phone UI toggle.
            if (peer != null) internet.revokeAllAuthenticated(peer)
        }
    }
    override fun close() { ble.close(); advertising = false; coordinator.close(); internet.close(); shell.close() }
    companion object {
        @Volatile var current: ForegroundConnectivityRuntime? = null
        fun hasNearbyPermissions(context: Context): Boolean {
            val required = mutableListOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
            if (Build.VERSION.SDK_INT >= 33) required += Manifest.permission.NEARBY_WIFI_DEVICES
            else required += Manifest.permission.ACCESS_FINE_LOCATION
            if (Build.VERSION.SDK_INT >= 37) required += Manifest.permission.ACCESS_LOCAL_NETWORK
            return required.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        }
    }
}
