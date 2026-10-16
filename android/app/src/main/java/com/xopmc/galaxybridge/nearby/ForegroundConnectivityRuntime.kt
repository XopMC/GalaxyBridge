package com.xopmc.galaxybridge.nearby

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.xopmc.galaxybridge.internet.InternetGatewayRuntime
import com.xopmc.galaxybridge.transport.NearbyBootstrapCoordinator

/** Process-local owner, installed only after Service.startForeground(connectedDevice). */
class ForegroundConnectivityRuntime(private val context: Context, private val isOwner: () -> Boolean,
    companionPort: () -> Int) : AutoCloseable {
    val shell = com.xopmc.galaxybridge.transport.shell.ShellBridgeRuntime(context, isOwner)
    val coordinator = NearbyBootstrapCoordinator(context, isOwner, companionPort)
    val internet = InternetGatewayRuntime(context, isOwner) { }
    private val ble = NearbyBlePeripheral(context, isOwner, coordinator::newSession,
        onError = {
            if (!closed) {
                latestNearbyError = it
                NearbyDiscoveryStatusBus.publish(NearbyDiscoveryStatus.Unavailable)
            }
        },
        onStarted = {
            if (!closed) {
                latestNearbyError = ""
                NearbyDiscoveryStatusBus.publish(NearbyDiscoveryStatus.Available)
            }
        })
    @Volatile var latestNearbyError: String = ""
        private set
    private val preferences = context.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    private var advertising = false
    private var closed = false
    private var bluetoothReceiverRegistered = false
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (closed || !isOwner() || intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            // Old GATT/advertiser objects belong to the old radio lifetime, even
            // if a fast OFF/ON cycle delivered only its final state. Requery the
            // live adapter in refresh; never act on broadcast state extras.
            retireBootstrap()
            refresh()
        }
    }
    fun start() { internet.start(); refresh() }
    fun refresh() {
        if (closed || !isOwner()) return
        val enabled = preferences.getBoolean("nearby_enabled", false)
        val permissionsGranted = hasNearbyPermissions(context)
        val observingRadio = !enabled || !permissionsGranted || ensureBluetoothReceiver()
        val radioOn = observingRadio && permissionsGranted && runCatching {
            context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
        }.getOrDefault(false)
        when (NearbyDiscoveryRecovery.decide(enabled, permissionsGranted, radioOn, advertising && ble.isRunningRequested)) {
            NearbyDiscoveryAction.StartBootstrap -> {
                NearbyDiscoveryStatusBus.publish(NearbyDiscoveryStatus.Starting)
                ble.start(); advertising = true
            }
            NearbyDiscoveryAction.RetireBootstrap -> {
                retireBootstrap()
                NearbyDiscoveryStatusBus.publish(NearbyDiscoveryStatus.Unavailable)
            }
            NearbyDiscoveryAction.Disable -> {
                retireBootstrap()
                // Opt-out/permission revocation retires groups independently of
                // BLE state. Radio loss alone must retain established TLS leases.
                coordinator.disable()
                NearbyDiscoveryStatusBus.publish(if (enabled) NearbyDiscoveryStatus.Unavailable else NearbyDiscoveryStatus.Disabled)
            }
            NearbyDiscoveryAction.Keep -> Unit
        }
        if (!preferences.getBoolean("internet_sharing_allowed", false)) {
            val peer = preferences.getString("paired_host_id", null)
            // All leases are individually session-fenced; revokeAll is needed for the phone UI toggle.
            if (peer != null) internet.revokeAllAuthenticated(peer)
        }
    }
    private fun retireBootstrap() {
        if (advertising || ble.isRunningRequested) ble.close()
        advertising = false
    }
    private fun ensureBluetoothReceiver(): Boolean {
        if (bluetoothReceiverRegistered) return true
        return runCatching {
            // Bluetooth broadcasts can originate from a privileged non-system UID.
            // This filter contains only AOSP's protected ACTION_STATE_CHANGED.
            ContextCompat.registerReceiver(context, bluetoothStateReceiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_EXPORTED)
            bluetoothReceiverRegistered = true
            true
        }.getOrElse {
            latestNearbyError = "ble_state_monitor_unavailable"
            false
        }
    }
    override fun close() {
        closed = true
        if (bluetoothReceiverRegistered) {
            runCatching { context.unregisterReceiver(bluetoothStateReceiver) }
            bluetoothReceiverRegistered = false
        }
        ble.close(); advertising = false; coordinator.close(); internet.close(); shell.close()
        NearbyDiscoveryStatusBus.publish(NearbyDiscoveryStatus.Disabled)
    }
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
