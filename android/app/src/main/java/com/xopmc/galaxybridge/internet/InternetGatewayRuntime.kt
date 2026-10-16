package com.xopmc.galaxybridge.internet

import android.content.Context
import android.net.DnsResolver
import android.os.CancellationSignal
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.SystemClock
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class InternetGatewayStatus(val enabled: Boolean, val upstream: String, val internetValidated: Boolean,
    val errorCode: String, val bytesSent: Long, val bytesReceived: Long)

/** A single instance belongs to the connectedDevice foreground service. Opt-in leases only.
 * All public bridge callers MUST already have authenticated their companion TLS session.
 * DNS and internet sockets live in the native adapter bound to selected Network.getNetworkHandle(). */
class InternetGatewayRuntime(
    context: Context,
    private val isForegroundOwner: () -> Boolean,
    private val onStatus: (InternetGatewayStatus) -> Unit,
) : AutoCloseable {
    private val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val lock = Any()
    private val leases = InternetLeaseRegistry(now = SystemClock::elapsedRealtime,
        onPeerRotation = { peer -> closeBridges { it.peerID == peer } })
    private val control = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
    private val refreshQueued = AtomicBoolean(false)
    private val relay = ThreadPoolExecutor(64, 64, 30, TimeUnit.SECONDS, ArrayBlockingQueue(64), ThreadPoolExecutor.AbortPolicy())
    private val connections = linkedMapOf<Socket, Bridge>()
    private class DnsClient(val peerID: String, val sessionID: String, val leaseID: String, val cancel: () -> Unit) {
        @Volatile var signal: CancellationSignal? = null
    }
    private val dnsClients = linkedMapOf<String, DnsClient>()
    private val dnsCallbacks = ThreadPoolExecutor(4, 4, 30, TimeUnit.SECONDS, ArrayBlockingQueue(64), ThreadPoolExecutor.AbortPolicy())
    private val lostNetworks = linkedSetOf<Long>()
    private val knownNetworks = linkedMapOf<Long, Network>()
    private val sent = AtomicLong()
    private val received = AtomicLong()
    private var latestError = ""
    private var started = false
    private var closed = false
    private var selected: UpstreamCandidate? = null
    private var requiredVpn: Long? = null
    private var nativeHandle = 0L
    private var nativePort = 0
    private var nativeStopping = false
    private var username = ""
    private var password = ""
    private class Bridge(val peerID: String, val sessionID: String, val leaseID: String, val cancel: () -> Unit)
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { synchronized(lock) { lostNetworks.remove(network.networkHandle) }; refresh() }
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { refresh() }
        override fun onLost(network: Network) {
            synchronized(lock) {
                lostNetworks.add(network.networkHandle)
                while (lostNetworks.size > 256) lostNetworks.remove(lostNetworks.first())
            }
            refresh()
        }
    }

    // Default changes include VPN activation even if the physical Wi-Fi remains available.
    private val defaultCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { refresh() }
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { refresh() }
        override fun onLost(network: Network) { refresh() }
    }

    /** Foreground lifetime begins here, but no native proxy starts until an opt-in lease. */
    fun start() = synchronized(lock) {
        check(!closed && isForegroundOwner()) { "foreground_owner_required" }
        if (started) return@synchronized
        try {
            connectivity.registerNetworkCallback(NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), callback)
            connectivity.registerDefaultNetworkCallback(defaultCallback)
        } catch (error: RuntimeException) {
            runCatching { connectivity.unregisterNetworkCallback(callback) }
            runCatching { connectivity.unregisterNetworkCallback(defaultCallback) }
            throw error
        }
        started = true
        control.scheduleAtFixedRate({ runCatching { reap() } }, 1, 1, TimeUnit.SECONDS)
        refresh()
    }

    /** Only call after the user opted in and the existing paired-session verifier admitted peerID/sessionID. */
    fun enableAuthenticated(peerID: String, sessionID: String, leaseID: String? = null, durationMillis: Long = 3_600_000): InternetLease = synchronized(lock) {
        check(started && !closed && isForegroundOwner()) { "foreground_owner_required" }
        val lease = leases.enable(peerID, sessionID, durationMillis, leaseID)
        refreshLocked()
        if (selected == null) publish(if (requiredVpn != null) "vpn_upstream_unavailable" else "no_validated_upstream")
        else if (!ensureNativeLocked()) publish("native_gateway_unavailable")
        else publish("")
        lease
    }

    fun renewAuthenticated(peerID: String, sessionID: String) = synchronized(lock) { leases.renew(peerID, sessionID) }

    fun revokeAuthenticated(peerID: String, sessionID: String) = synchronized(lock) {
        leases.revoke(peerID, sessionID)
        closeBridges { it.peerID == peerID && it.sessionID == sessionID }
        if (!leases.hasActive()) stopNativeLocked()
        publish("")
    }

    fun revokeAll() = synchronized(lock) {
        leases.clear(); closeBridges { true }; stopNativeLocked(); publish("")
    }

    fun revokeAllAuthenticated(peerID: String) = synchronized(lock) {
        leases.revokePeer(peerID)
        closeBridges { it.peerID == peerID }
        if (!leases.hasActive()) stopNativeLocked()
        publish("")
    }

    fun admits(peerID: String, sessionID: String, leaseID: String): Boolean = synchronized(lock) {
        !closed && isForegroundOwner() && leases.admits(peerID, sessionID, leaseID) && selected != null && ensureNativeLocked()
    }

    /** Blocking: root routes INTERNET_PROXY here after authentication, lease check and readiness.
     * cancel closes the root-owned TLS socket on lease expiry, revoke, owner stop, or uplink loss. */
    fun bridgeAuthenticated(input: InputStream, output: OutputStream, peerID: String, sessionID: String,
        leaseID: String, cancel: () -> Unit = { runCatching { input.close() }; runCatching { output.close() } }) {
        val local = synchronized(lock) {
            check(admits(peerID, sessionID, leaseID)) { "gateway_lease_or_upstream_unavailable" }
            check(connections.size + dnsClients.size < 32) { "gateway_connection_limit" }
            Socket().apply {
                soTimeout = 15_000
                connect(InetSocketAddress(LOOPBACK, nativePort), 3_000)
                connections[this] = Bridge(peerID, sessionID, leaseID, cancel)
            }
        }
        val handshakeDeadline = control.schedule({ runCatching { local.close() }; runCatching(cancel) }, 15, TimeUnit.SECONDS)
        try {
            // Native RFC1929 credentials stay private to this process, never cross the Mac channel.
            authenticateNative(local)
            GatewaySocksHandshake.acceptClient(input, output)
            handshakeDeadline.cancel(false)
            local.soTimeout = 0
            val upload = relay.submit {
                try { pump(input, local.getOutputStream(), sent) }
                finally { runCatching { local.shutdownOutput() } }
            }
            try { pump(local.getInputStream(), output, received) }
            finally { upload.cancel(true) }
        } finally {
            handshakeDeadline.cancel(false)
            synchronized(lock) { connections.remove(local) }
            runCatching { local.close() }
            runCatching(cancel)
        }
    }

    /** Dedicated authenticated DNS-over-TCP wire channel. The phone's selected
     * Network resolver (including Private DNS) processes every raw query; no fixed public DNS. */
    fun handleDnsAuthenticated(input: InputStream, output: OutputStream, peerID: String, sessionID: String,
        leaseID: String, cancel: () -> Unit = { runCatching { input.close() }; runCatching { output.close() } }) {
        val id = UUID.randomUUID().toString()
        val client = DnsClient(peerID, sessionID, leaseID, cancel)
        synchronized(lock) {
            check(admits(peerID, sessionID, leaseID)) { "gateway_lease_or_upstream_unavailable" }
            check(connections.size + dnsClients.size < 32) { "gateway_connection_limit" }
            dnsClients[id] = client
        }
        try {
            repeat(32) {
                val deadlineMillis = SystemClock.elapsedRealtime() + 8_000
                val deadline = control.schedule({ client.signal?.cancel(); runCatching(cancel) }, 8, TimeUnit.SECONDS)
                val signal = CancellationSignal()
                client.signal = signal
                try {
                    val query = DnsWirePolicy.readQuery(input)
                    val (handle, network) = synchronized(lock) {
                        check(dnsClients[id] === client && leases.admits(peerID, sessionID, leaseID) && isForegroundOwner())
                        val handle = requireNotNull(selected).handle
                        handle to requireNotNull(knownNetworks[handle])
                    }
                    val completion = CompletableFuture<ByteArray>()
                    DnsResolver.getInstance().rawQuery(network, query, DnsResolver.FLAG_EMPTY, dnsCallbacks, signal,
                        object : DnsResolver.Callback<ByteArray> {
                            override fun onAnswer(answer: ByteArray, rcode: Int) { completion.complete(answer) }
                            override fun onError(error: DnsResolver.DnsException) { completion.completeExceptionally(error) }
                        })
                    val answer = completion.get((deadlineMillis - SystemClock.elapsedRealtime()).coerceAtLeast(1), TimeUnit.MILLISECONDS)
                    synchronized(lock) {
                        check(dnsClients[id] === client && leases.admits(peerID, sessionID, leaseID) &&
                            selected?.handle == handle && isForegroundOwner()) { "dns_upstream_or_lease_changed" }
                    }
                    DnsWirePolicy.writeAnswer(output, query, answer)
                    sent.addAndGet(query.size.toLong()); received.addAndGet(answer.size.toLong())
                } finally { signal.cancel(); client.signal = null; deadline.cancel(false) }
            }
        } finally {
            synchronized(lock) { dnsClients.remove(id) }
            client.signal?.cancel(); runCatching(cancel)
        }
    }

    private fun authenticateNative(socket: Socket) {
        val credentials = synchronized(lock) { username to password }
        GatewaySocksHandshake.authenticateNative(socket.getInputStream(), socket.getOutputStream(), credentials.first, credentials.second)
    }

    private fun pump(input: InputStream, output: OutputStream, counter: AtomicLong) {
        val buffer = ByteArray(32 * 1024)
        while (!Thread.currentThread().isInterrupted) {
            val count = input.read(buffer)
            if (count < 0) return
            if (count == 0) continue
            output.write(buffer, 0, count); output.flush()
            counter.addAndGet(count.toLong())
        }
    }

    private fun refresh() {
        if (!control.isShutdown && refreshQueued.compareAndSet(false, true)) {
            try { control.execute { refreshQueued.set(false); synchronized(lock) { if (!closed) refreshLocked() } } }
            catch (_: java.util.concurrent.RejectedExecutionException) { refreshQueued.set(false) }
        }
    }
    private fun refreshLocked() {
        knownNetworks.clear()
        val active = connectivity.activeNetwork
        val activeCaps = active?.let(connectivity::getNetworkCapabilities)
        // Keep the VPN fence during an unknown default/capability transition.
        // Only a known replacement default can clear it.
        if (activeCaps != null) requiredVpn = active.takeIf {
            activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }?.networkHandle
        val networks = (connectivity.allNetworks.toList() + listOfNotNull(active)).distinctBy { it.networkHandle }
        val candidates = networks.mapNotNull { network ->
            if (network.networkHandle in lostNetworks) return@mapNotNull null
            val caps = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return@mapNotNull null
            val isVpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            if (isVpn && network.networkHandle != requiredVpn) return@mapNotNull null
            val kind = when {
                isVpn -> UpstreamKind.VPN
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> UpstreamKind.WIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> UpstreamKind.CELLULAR
                else -> UpstreamKind.OTHER
            }
            val handle = network.networkHandle
            knownNetworks[handle] = network
            UpstreamCandidate(handle, kind, caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
        }
        val next = UpstreamSelectionPolicy.select(candidates, selected?.handle, requiredVpn, activeCaps != null)
        if (next == selected) return
        val retire = UpstreamSelectionPolicy.requiresRetirement(selected, next)
        selected = next
        if (retire) {
            closeBridges { true }
            stopNativeLocked()
        }
        if (next == null) {
            closeBridges { true }
            stopNativeLocked()
            publish(if (requiredVpn != null) "vpn_upstream_unavailable" else "no_validated_upstream")
        } else {
            if (nativeHandle != 0L && NativeInternetGateway.updateNetwork(nativeHandle, next.handle) != 0) {
                closeBridges { true }; stopNativeLocked(); publish("upstream_binding_failed")
            } else publish("")
        }
    }
    private fun ensureNativeLocked(): Boolean {
        if (nativeStopping) {
            stopNativeLocked()
            if (nativeStopping) return false
        }
        if (nativeHandle != 0L) return true
        val upstream = selected ?: return false
        if (!NativeInternetGateway.load()) return false
        repeat(3) {
            val port = ServerSocket(0, 1, LOOPBACK).use { it.localPort }
            val random = SecureRandom()
            fun secret() = ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it) }
            val user = secret(); val pass = secret()
            val handle = runCatching { NativeInternetGateway.start("port: $port\nusername: $user\npassword: $pass\n", upstream.handle) }.getOrDefault(0L)
            if (handle != 0L) {
                val actualPort = NativeInternetGateway.localPort(handle)
                if (actualPort == port) {
                    nativeHandle = handle; nativePort = port; username = user; password = pass; latestError = ""
                    return true
                }
                NativeInternetGateway.stop(handle)
            }
        }
        return false
    }
    private fun stopNativeLocked() {
        val handle = nativeHandle
        if (handle == 0L) return
        nativeStopping = true
        val result = runCatching { NativeInternetGateway.stop(handle) }.getOrDefault(-1)
        if (result == 0 || result == 2) {
            nativeHandle = 0; nativePort = 0; username = ""; password = ""; nativeStopping = false
        }
    }
    private fun closeBridges(predicate: (Bridge) -> Boolean) {
        dnsClients.entries.filter { predicate(Bridge(it.value.peerID, it.value.sessionID, it.value.leaseID, it.value.cancel)) }
            .toList().forEach { (id, client) ->
                dnsClients.remove(id); client.signal?.cancel(); runCatching(client.cancel)
            }
        connections.entries.filter { predicate(it.value) }.toList().forEach { (socket, bridge) ->
            connections.remove(socket); runCatching { socket.close() }; runCatching(bridge.cancel)
        }
    }
    private fun reap() = synchronized(lock) {
        if (closed) return@synchronized
        if (!isForegroundOwner()) { close(); return@synchronized }
        closeBridges { !leases.admits(it.peerID, it.sessionID, it.leaseID) }
        if (!leases.hasActive()) stopNativeLocked()
    }
    fun status(error: String? = null): InternetGatewayStatus = synchronized(lock) {
        InternetGatewayStatus(started && !closed && leases.hasActive() && nativeHandle != 0L && !nativeStopping, selected?.kind?.name?.lowercase() ?: "unavailable",
            false, error ?: latestError, sent.get(), received.get())
    }
    private fun publish(error: String) { latestError = error; onStatus(status()) }
    override fun close() = synchronized(lock) {
        if (closed) return@synchronized
        closed = true
        leases.clear(); closeBridges { true }; stopNativeLocked()
        if (started) {
            runCatching { connectivity.unregisterNetworkCallback(callback) }
            runCatching { connectivity.unregisterNetworkCallback(defaultCallback) }
        }
        started = false
        relay.shutdownNow(); dnsCallbacks.shutdownNow()
        if (nativeStopping) {
            // A timed-out native join retains its owner. Retry on this bounded cleanup
            // worker rather than losing the only handle and wedging the next service.
            control.execute {
                repeat(3) { synchronized(lock) { if (nativeStopping) stopNativeLocked() } }
                control.shutdownNow()
            }
        } else control.shutdownNow()
        publish("")
    }
    companion object {
        private val LOOPBACK = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
    }
}
