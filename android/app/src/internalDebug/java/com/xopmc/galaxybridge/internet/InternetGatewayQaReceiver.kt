package com.xopmc.galaxybridge.internet

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.os.SystemClock
import android.util.AtomicFile
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime
import org.json.JSONObject
import java.io.DataInputStream
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** InternalDebug and DUMP only. Never changes pairing, user opt-in, radios, routes, or settings.
 * Host framing: exact 32 secret bytes, op byte 1=SOCKS / 2=DNS, then real runtime wire bytes.
 * No extra success prefix. Invalid authentication closes the socket without a response. */
class InternetGatewayQaReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("run_id")
        val token = intent.getStringExtra("token")
        val operation = intent.getStringExtra("operation")
        if (intent.action != ACTION || !BuildConfig.DEBUG || BuildConfig.DISTRIBUTION != "internal" ||
            !InternetGatewayQaGuard.valid(id, token, operation)) {
            resultCode = 2; resultData = "invalid_qa_request"; return
        }
        val pending = goAsync()
        try {
            requests.execute {
                try {
                    val result = execute(context.applicationContext, id!!, token!!, operation!!)
                    pending.resultCode = if (result.optString("state") in setOf("rejected", "failed")) 3 else 0
                    pending.resultData = result.toString()
                } catch (_: Exception) {
                    pending.resultCode = 3; pending.resultData = "fixture_failed"
                } finally { pending.finish() }
            }
        } catch (_: Exception) { pending.resultCode = 3; pending.resultData = "fixture_busy"; pending.finish() }
    }

    companion object {
        const val ACTION = "com.xopmc.galaxybridge.QA_INTERNET_GATEWAY"
        private val requests = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue(8))
        private var current: GatewayQaRun? = null
        private fun execute(context: Context, id: String, token: String, operation: String): JSONObject {
            var run = current
            if (operation == "prepare" && (run == null || (run.closed.get() && run.guard.runID != id))) {
                if (File(context.filesDir, "internet-gateway-qa/$id/receipt.json").exists()) return rejected("run_id_already_used")
                run = GatewayQaRun(context, id, token)
                current = run
                run.start()
            }
            if (run == null || !run.guard.matches(id, token)) return rejected("run_not_owned")
            if (operation == "cleanup") run.close("cleaned")
            return run.receipt()
        }
        private fun rejected(error: String) = JSONObject().put("state", "rejected").put("error", error)
    }
}

private class GatewayQaRun(private val context: Context, id: String, token: String) {
    val guard = InternetGatewayQaGuard(id, token, SystemClock.elapsedRealtime())
    val closed = AtomicBoolean(false)
    private val secret = token.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private val owner = ForegroundConnectivityRuntime.current
    private val preferences = context.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    private val peer = UUID.randomUUID().toString()
    private val session = UUID.randomUUID().toString()
    private val lease = UUID.randomUUID().toString()
    private val socketLock = Any()
    private val sockets = linkedSetOf<Socket>()
    private val rejected = AtomicInteger()
    private val socks = AtomicInteger()
    private val dns = AtomicInteger()
    private val scheduler = ScheduledThreadPoolExecutor(2).apply { removeOnCancelPolicy = true }
    private val workers = ThreadPoolExecutor(16, 16, 0, TimeUnit.SECONDS, ArrayBlockingQueue(16))
    private val listener = ServerSocket()
    private val wake = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GalaxyBridge:InternetGatewayQa").apply { setReferenceCounted(false) }
    private val runtime = InternetGatewayRuntime(context, ::ownsForeground) { }
    private val file = File(context.filesDir, "internet-gateway-qa/$id/receipt.json")
    @Volatile private var state = "preparing"
    @Volatile private var error = ""
    @Volatile private var port = 0
    @Volatile private var runtimeCloseFinished = false
    @Volatile private var lastStatus: InternetGatewayStatus? = null

    private fun ownsForeground() = !closed.get() && SystemClock.elapsedRealtime() < guard.deadline &&
        owner != null && ForegroundConnectivityRuntime.current === owner &&
        !preferences.getBoolean("internet_sharing_allowed", false)

    fun start() {
        try {
            check(ownsForeground()) { "foreground_required_or_user_modem_enabled" }
            check(owner?.internet?.status()?.enabled == false) { "user_modem_active" }
            wake.acquire((guard.deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1))
            scheduler.schedule({ close("expired") }, (guard.deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1), TimeUnit.MILLISECONDS)
            runtime.start()
            runtime.enableAuthenticated(peer, session, lease, (guard.deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1))
            val status = runtime.status()
            check(status.enabled) { status.errorCode.ifEmpty { "native_gateway_unavailable" } }
            check(ownsForeground()) { "foreground_owner_lost" }
            listener.bind(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), 0), 16)
            port = listener.localPort
            state = "prepared"
            Thread({ accept() }, "internet-qa-loopback").start()
            scheduler.scheduleAtFixedRate({ if (!ownsForeground()) close("owner_lost") else receipt() }, 1, 1, TimeUnit.SECONDS)
            receipt()
        } catch (failure: Exception) {
            error = when (failure.message) {
                "foreground_required_or_user_modem_enabled", "user_modem_active", "no_validated_upstream", "native_gateway_unavailable", "foreground_owner_lost" -> failure.message!!
                else -> "fixture_initialization_failed"
            }
            close("failed")
        }
    }

    private fun accept() {
        while (!closed.get()) {
            val socket = try { listener.accept() } catch (_: Exception) { break }
            val admitted = synchronized(socketLock) {
                if (closed.get() || sockets.size >= 16 || !socket.inetAddress.isLoopbackAddress) false
                else { sockets.add(socket); true }
            }
            if (!admitted) { socket.close(); continue }
            try { workers.execute { serve(socket) } }
            catch (_: Exception) { synchronized(socketLock) { sockets.remove(socket) }; socket.close() }
        }
    }

    private fun serve(socket: Socket) {
        try {
            socket.soTimeout = 2_000
            val input = DataInputStream(socket.getInputStream())
            val supplied = ByteArray(32)
            input.readFully(supplied)
            val authenticated = synchronized(secret) { MessageDigest.isEqual(secret, supplied) }
            supplied.fill(0)
            if (!authenticated || !ownsForeground()) { rejected.incrementAndGet(); return }
            val operation = input.readUnsignedByte()
            socket.soTimeout = (guard.deadline - SystemClock.elapsedRealtime()).coerceIn(1, 30_000).toInt()
            when (operation) {
                1 -> { socks.incrementAndGet(); runtime.bridgeAuthenticated(input, socket.getOutputStream(), peer, session, lease) { socket.close() } }
                2 -> { dns.incrementAndGet(); runtime.handleDnsAuthenticated(input, socket.getOutputStream(), peer, session, lease) { socket.close() } }
                else -> rejected.incrementAndGet()
            }
        } catch (_: Exception) { /* Per-connection failure contains no user data in receipts. */ }
        finally { synchronized(socketLock) { sockets.remove(socket) }; runCatching { socket.close() }; receipt() }
    }

    /** Close public-facing resources before possibly waiting on native retirement. */
    fun close(reason: String) {
        if (!closed.compareAndSet(false, true)) return
        state = reason
        runCatching { listener.close() }
        synchronized(socketLock) { sockets.forEach { runCatching { it.close() } }; sockets.clear() }
        synchronized(secret) { secret.fill(0) }
        if (wake.isHeld) runCatching { wake.release() }
        workers.shutdownNow()
        scheduler.shutdownNow()
        receipt(includeRuntime = false)
        runCatching { runtime.close() }
        runtimeCloseFinished = true
        receipt(includeRuntime = false)
    }

    @Synchronized fun receipt(includeRuntime: Boolean = !closed.get()): JSONObject {
        if (includeRuntime) runCatching { runtime.status() }.getOrNull()?.let { lastStatus = it }
        val status = lastStatus
        val report = JSONObject().put("run_id", guard.runID).put("state", state).put("error", error)
            .put("port", port).put("receipt_path", file.absolutePath)
            .put("remaining_ms", (guard.deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0))
            .put("active_clients", synchronized(socketLock) { sockets.size })
            .put("socks_sessions", socks.get()).put("dns_sessions", dns.get()).put("rejected", rejected.get())
            .put("listener_closed", listener.isClosed).put("wake_held", wake.isHeld)
            .put("runtime_close_finished", runtimeCloseFinished)
            .put("upstream", status?.upstream ?: "").put("bytes_sent", status?.bytesSent ?: 0)
            .put("bytes_received", status?.bytesReceived ?: 0)
        runCatching {
            file.parentFile!!.mkdirs()
            val atomic = AtomicFile(file)
            val stream = atomic.startWrite()
            try { stream.write(report.toString().toByteArray()); atomic.finishWrite(stream) }
            catch (failure: Exception) { atomic.failWrite(stream); throw failure }
        }
        return report
    }
}
