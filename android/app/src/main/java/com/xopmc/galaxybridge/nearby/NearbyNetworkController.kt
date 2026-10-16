package com.xopmc.galaxybridge.nearby

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.NetworkInterface
import java.util.UUID

/** Credentials are bootstrap secrets. Never log/advertise this value. */
class NearbyNetworkOffer(
    val leaseID: String,
    val generation: Long,
    val kind: NearbyLinkKind,
    val networkName: String,
    val passphrase: String,
    val ownerAddress: String,
    val interfaceName: String,
    val ownerDeviceAddress: String?,
    val localAddresses: List<String>,
    val upstreamWifiPreserved: Boolean = false,
)

/** Owner MUST be the running connectedDevice foreground service; close on its destruction.
 * All operations serialize on main, and never change Wi-Fi enablement or remove unrelated groups. */
class NearbyNetworkController(
    context: Context,
    private val isForegroundOwner: () -> Boolean,
    private val onOffer: (NearbyNetworkOffer) -> Unit,
    private val onError: (String) -> Unit,
) : AutoCloseable {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val wifi = this.context.getSystemService(WifiManager::class.java)
    private val connectivity = this.context.getSystemService(ConnectivityManager::class.java)
    private val p2p = this.context.getSystemService(WifiP2pManager::class.java)
    private var channel: WifiP2pManager.Channel? = null
    private var generation = 0L
    private var operation: Operation? = null
    private var registered = false
    private var closed = false
    private data class Operation(val generation: Long, val kind: NearbyLinkKind, val name: String, val passphrase: String,
        val leaseID: String = UUID.randomUUID().toString(), var closing: Boolean = false,
        val ownership: NearbyGroupOwnership = NearbyGroupOwnership(name, kind == NearbyLinkKind.P2P_OWNER), var reservation: WifiManager.LocalOnlyHotspotReservation? = null,
        val baseline: Set<Pair<String, String>> = emptySet(), var cleanupPolls: Int = 0, var cleanupPollScheduled: Boolean = false,
        var wifiCallback: ConnectivityManager.NetworkCallback? = null, val stationHandles: Set<Long> = emptySet())
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION) operation?.let(::inspectGroup)
        }
    }

    /** A verified model/runtime profile must explicitly approve STA+P2P. No public API proves it. */
    fun createGroup(networkName: String, passphrase: String, staP2pConcurrencyVerified: Boolean = false) = handler.post {
        startP2p(NearbyLinkKind.P2P_OWNER, networkName, passphrase, staP2pConcurrencyVerified)
    }

    /** Join the exact offered shared group; the Mac stays on the first phone's group. */
    fun joinGroup(networkName: String, passphrase: String, staP2pConcurrencyVerified: Boolean = false) = handler.post {
        startP2p(NearbyLinkKind.P2P_JOIN, networkName, passphrase, staP2pConcurrencyVerified)
    }

    /** Joins an authenticated LOHS offer without replacing a station on unverified hardware.
     * Android may show its system Wi-Fi consent dialog. No process-wide network binding. */
    fun joinLocalOnlyHotspot(networkName: String, passphrase: String, ownerAddress: String) = handler.post {
        if (!admit(NearbyLinkKind.LOCAL_WIFI_JOIN, wifi.isStaConcurrencyForLocalOnlyConnectionsSupported)) return@post
        if (networkName.isBlank() || networkName.toByteArray().size > 32 || passphrase.length !in 8..63 ||
            !ownerAddress.matches(Regex("[0-9.]{7,15}"))) { onError("invalid_group_credentials"); return@post }
        val op = Operation(++generation, NearbyLinkKind.LOCAL_WIFI_JOIN, networkName, passphrase, stationHandles = stationHandles())
        operation = op
        try {
            val callback = object : ConnectivityManager.NetworkCallback() {
                private fun publish(network: Network, properties: LinkProperties?) {
                    if (operation !== op || op.closing || !isForegroundOwner()) return
                    val iface = properties?.interfaceName ?: return
                    val local = properties.linkAddresses.map { it.address }.filter { it.address.size == 4 && !it.isLoopbackAddress }.mapNotNull { it.hostAddress }
                    if (local.isEmpty() || !verifyStationPreserved(op)) return
                    onOffer(NearbyNetworkOffer(op.leaseID, op.generation, op.kind, networkName, passphrase,
                        ownerAddress, iface, null, local, true))
                }
                override fun onAvailable(network: Network) { publish(network, connectivity.getLinkProperties(network)) }
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) { publish(network, properties) }
                override fun onUnavailable() {
                    if (operation === op) { operation = null; onError("local_wifi_join_unavailable") }
                    runCatching { connectivity.unregisterNetworkCallback(this) }
                }
                override fun onLost(network: Network) {
                    if (operation === op) { operation = null; onError("local_wifi_join_lost") }
                    runCatching { connectivity.unregisterNetworkCallback(this) }
                }
            }
            op.wifiCallback = callback
            val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(WifiNetworkSpecifier.Builder().setSsid(networkName).setWpa2Passphrase(passphrase).build()).build()
            connectivity.requestNetwork(request, callback, handler, 30_000)
        } catch (_: Exception) { operation = null; onError("local_wifi_join_permission_failed") }
    }

    private fun startP2p(kind: NearbyLinkKind, name: String, passphrase: String, verified: Boolean) {
        if (!admit(kind, verified)) return
        if (!name.matches(Regex("DIRECT-[A-Za-z0-9]{2}.+")) || name.toByteArray().size > 32 ||
            passphrase.length !in 8..63 || passphrase.any { it.code !in 32..126 }) {
            onError("invalid_group_credentials"); return
        }
        try {
            val manager = p2p ?: run { onError("wifi_direct_unavailable"); return }
            if (channel == null) channel = manager.initialize(context, handler.looper) {
                operation?.closing = true
                onError("wifi_direct_channel_lost")
            }
            val activeChannel = channel ?: run { onError("wifi_direct_channel_unavailable"); return }
            if (!registered) {
                val filter = IntentFilter(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
                if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                else context.registerReceiver(receiver, filter)
                registered = true
            }
            val op = Operation(++generation, kind, name, passphrase, stationHandles = stationHandles())
            operation = op
            // Inspect before mutation. Never adopt or remove an already existing group.
            manager.requestGroupInfo(activeChannel) { existing ->
                if (operation !== op) return@requestGroupInfo
                if (existing != null) { operation = null; onError("wifi_direct_group_already_exists"); return@requestGroupInfo }
                if (op.closing || !isForegroundOwner()) { operation = null; return@requestGroupInfo }
                val config = WifiP2pConfig.Builder().setNetworkName(name).setPassphrase(passphrase)
                    .enablePersistentMode(false).build()
                val listener = object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { inspectGroup(op) }
                    override fun onFailure(reason: Int) {
                        if (operation === op) { operation = null; onError("wifi_direct_start_failed_$reason") }
                    }
                }
                if (kind == NearbyLinkKind.P2P_OWNER) manager.createGroup(activeChannel, config, listener)
                else manager.connect(activeChannel, config, listener)
                handler.postDelayed({
                    if (operation === op && op.ownership.identity == null) {
                        op.closing = true
                        inspectGroup(op)
                        onError("wifi_direct_start_timeout")
                        // Keep this generation fenced until its real OS callback resolves.
                    }
                }, 30_000)
            }
        } catch (_: Exception) { operation = null; onError("wifi_direct_permission_or_configuration_failed") }
    }

    fun startLocalOnlyHotspot() = handler.post {
        if (!admit(NearbyLinkKind.LOCAL_HOTSPOT, false)) return@post
        val op = Operation(++generation, NearbyLinkKind.LOCAL_HOTSPOT, "", "", baseline = addresses().toSet(), stationHandles = stationHandles())
        operation = op
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                    if (operation !== op || op.closing || !isForegroundOwner()) { reservation.close(); if (operation === op) operation = null; return }
                    op.reservation = reservation
                    pollHotspot(op, 0)
                }
                override fun onStopped() { if (operation === op) { operation = null; onError("local_hotspot_stopped") } }
                override fun onFailed(reason: Int) { if (operation === op) { operation = null; onError("local_hotspot_failed_$reason") } }
            }, handler)
            handler.postDelayed({
                if (operation === op && op.reservation == null) { op.closing = true; onError("local_hotspot_start_timeout") }
            }, 20_000)
        } catch (_: Exception) { operation = null; onError("local_hotspot_permission_failed") }
    }

    private fun pollHotspot(op: Operation, attempt: Int) {
        if (operation !== op || op.closing) return
        // Exclude every system-managed upstream/STA interface, including a cellular
        // address that appeared concurrently. Never mistake it for our AP endpoint.
        val managedInterfaces = connectivity.allNetworks.mapNotNull { connectivity.getLinkProperties(it)?.interfaceName }.toSet()
        val candidates = addresses().filter { it !in op.baseline && it.first !in managedInterfaces }
        val candidate = candidates.singleOrNull()
        val config = op.reservation?.softApConfiguration
        if (candidate != null && config?.ssid != null && config.passphrase != null) {
            if (!verifyStationPreserved(op)) return
            onOffer(NearbyNetworkOffer(op.leaseID, op.generation, op.kind, config.ssid!!, config.passphrase!!,
                candidate.second, candidate.first, null, listOf(candidate.second), true))
        } else if (attempt < 20) handler.postDelayed({ pollHotspot(op, attempt + 1) }, 500)
        else { onError("local_hotspot_endpoint_unavailable"); stopOperation(op) }
    }

    private fun inspectGroup(op: Operation) {
        val manager = p2p ?: return
        val activeChannel = channel ?: return
        try {
            manager.requestGroupInfo(activeChannel) { group ->
                if (operation !== op) return@requestGroupInfo
                if (group == null) {
                    if (op.ownership.identity != null) { operation = null; onError("wifi_direct_group_lost") }
                    else if (op.closing && !op.cleanupPollScheduled) {
                        if (op.cleanupPolls++ < 60) {
                            op.cleanupPollScheduled = true
                            handler.postDelayed({ op.cleanupPollScheduled = false; if (operation === op) inspectGroup(op) }, 500)
                        } else onError("wifi_direct_cleanup_unverified")
                    }
                    return@requestGroupInfo
                }
                val identity = identity(group)
                if (!op.ownership.observe(identity)) { operation = null; onError("wifi_direct_group_not_owned"); return@requestGroupInfo }
                if (op.closing || closed || !isForegroundOwner()) { removeOwned(op); return@requestGroupInfo }
                manager.requestConnectionInfo(activeChannel) { info ->
                    if (operation !== op || op.closing || !info.groupFormed) return@requestConnectionInfo
                    val owner = info.groupOwnerAddress?.hostAddress ?: return@requestConnectionInfo
                    val local = addresses().filter { it.first == group.`interface` }.map { it.second }
                    if (local.isEmpty()) { handler.postDelayed({ inspectGroup(op) }, 300); return@requestConnectionInfo }
                    if (!verifyStationPreserved(op)) return@requestConnectionInfo
                    onOffer(NearbyNetworkOffer(op.leaseID, op.generation, op.kind, group.networkName,
                        group.passphrase ?: op.passphrase, owner, group.`interface`, group.owner?.deviceAddress, local, true))
                }
            }
        } catch (_: Exception) { onError("wifi_direct_inspection_failed") }
    }

    fun stop(leaseID: String? = null) = handler.post {
        operation?.takeIf { leaseID == null || it.leaseID == leaseID }?.let(::stopOperation)
    }
    private fun stopOperation(op: Operation) {
        op.closing = true
        if (op.kind == NearbyLinkKind.LOCAL_WIFI_JOIN) {
            op.wifiCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
            operation = null
        } else if (op.kind == NearbyLinkKind.LOCAL_HOTSPOT) {
            op.reservation?.close()
            // Pending reservation callbacks close their exact reservation when they arrive.
            if (op.reservation != null) operation = null
        } else if (op.ownership.identity != null) removeOwned(op) else inspectGroup(op)
    }
    private fun removeOwned(op: Operation) {
        val manager = p2p ?: return
        val activeChannel = channel ?: return
        manager.requestGroupInfo(activeChannel) { current ->
            if (operation !== op) return@requestGroupInfo
            if (current == null) { operation = null; return@requestGroupInfo }
            if (!op.ownership.mayRemove(identity(current))) { onError("wifi_direct_cleanup_not_owned"); operation = null; return@requestGroupInfo }
            manager.removeGroup(activeChannel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { if (operation === op) operation = null }
                override fun onFailure(reason: Int) { onError("wifi_direct_cleanup_failed_$reason") }
            })
        }
    }
    private fun identity(group: WifiP2pGroup) = NearbyGroupIdentity(group.networkName, group.`interface`, group.networkId, group.isGroupOwner)
    private fun admit(kind: NearbyLinkKind, verified: Boolean): Boolean {
        if (closed || !isForegroundOwner()) { onError("foreground_owner_required"); return false }
        if (operation != null) { onError("nearby_operation_busy"); return false }
        val sta = connectivity.allNetworks.any { network -> connectivity.getNetworkCapabilities(network)?.let {
            it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        } == true }
        val reason = NearbyRadioPolicy.rejection(sta, kind, verified, wifi.isStaApConcurrencySupported)
        if (reason != null) { onError(reason); return false }
        return true
    }
    private fun stationHandles(): Set<Long> = connectivity.allNetworks.filter {
        connectivity.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }.map { it.networkHandle }.toSet()
    private fun verifyStationPreserved(op: Operation): Boolean {
        if (stationHandles().containsAll(op.stationHandles)) return true
        onError("sta_connection_lost")
        stopOperation(op)
        return false
    }
    private fun addresses(): List<Pair<String, String>> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { iface ->
            iface.inetAddresses.toList().filter { !it.isLoopbackAddress && !it.isLinkLocalAddress && it.address.size == 4 }
                .map { iface.name to requireNotNull(it.hostAddress) }
        }
    }.getOrDefault(emptyList())
    override fun close() { handler.post {
        if (closed) return@post
        closed = true
        operation?.let(::stopOperation)
        if (registered) { context.unregisterReceiver(receiver); registered = false }
        // Keep channel alive for exact owned-group cleanup callbacks; never remove a foreign group.
    } }
}
