package com.xopmc.galaxybridge.transport.shell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.os.SystemClock
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.internet.InternetGatewayQaGuard
import com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellCaptureOptions
import java.io.DataInputStream
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
import org.json.JSONObject

/** InternalDebug/DUMP only. Tests one synthetic typed lease for at most30s.
 * Stream framing:32 secret bytes +1 video/2 control/3 clipboard, then production wire.
 * Never accepts a command, package, path, network destination, or external lease. */
class ShellBridgeQaReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("run_id")
        val token = intent.getStringExtra("token")
        val op = intent.getStringExtra("operation")
        val mode = intent.getStringExtra("mode") ?: "scrcpy"
        if (intent.action != ACTION || !BuildConfig.DEBUG || BuildConfig.DISTRIBUTION != "internal" ||
            !InternetGatewayQaGuard.valid(id, token, op) || mode !in setOf("scrcpy", "clipboard", "panel")) {
            resultCode = 2; resultData = "invalid_qa_request"; return
        }
        val pending = goAsync()
        try { requests.execute {
            try {
                var run = current
                if (op == "prepare" && (run == null || run.retirementFinished)) {
                    run = ShellQaRun(context.applicationContext, id!!, token!!, mode)
                    current = run; run.start()
                }
                if (run == null || !run.guard.matches(id!!, token!!)) {
                    pending.resultCode = 3; pending.resultData = "run_not_owned"
                } else {
                    if (op == "cleanup") run.close("cleaned")
                    pending.resultCode = if (run.state == "failed") 3 else 0
                    pending.resultData = run.receipt().toString()
                }
            } catch (_: Exception) { pending.resultCode = 3; pending.resultData = "fixture_failed" }
            finally { pending.finish() }
        } } catch (_: Exception) { pending.resultCode = 3; pending.resultData = "fixture_busy"; pending.finish() }
    }
    companion object {
        const val ACTION = "com.xopmc.galaxybridge.QA_SHELL_BRIDGE"
        private val requests = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue(8))
        private var current: ShellQaRun? = null
    }
}

private class ShellQaRun(context: Context, id: String, token: String, private val mode: String) {
    val guard = InternetGatewayQaGuard(id, token, SystemClock.elapsedRealtime())
    val closed = AtomicBoolean(false)
    private val secret = token.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private val foreground = ForegroundConnectivityRuntime.current
    private val runtime = foreground?.shell
    private val boot = runtime?.status()?.bootGeneration.orEmpty()
    private val peer = UUID.randomUUID().toString()
    private val session = UUID.randomUUID().toString()
    private val lease = UUID.randomUUID().toString()
    private val lock = Any()
    private val clients = linkedSetOf<Socket>()
    private val listener = ServerSocket()
    private val timer = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
    private val workers = ThreadPoolExecutor(8, 8, 0, TimeUnit.SECONDS, ArrayBlockingQueue(8))
    private val wake = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GalaxyBridge:ShellQa").apply { setReferenceCounted(false) }
    private var port = 0
    private var leaseStarted = false
    @Volatile var state = "preparing"
        private set
    @Volatile private var error = ""
    @Volatile var retirementFinished = false
        private set
    @Volatile private var retirementConfirmed = false
    private fun owns() = !closed.get() && SystemClock.elapsedRealtime() < guard.deadline &&
        foreground != null && ForegroundConnectivityRuntime.current === foreground &&
        runtime?.status()?.let { it.available && it.bootGeneration == boot } == true
    fun start() {
        try {
            check(owns())
            wake.acquire(45_000)
            timer.schedule({ close("expired") }, (guard.deadline-SystemClock.elapsedRealtime()).coerceAtLeast(1), TimeUnit.MILLISECONDS)
            val options = ShellCaptureOptions.newBuilder().setScid((System.nanoTime() and 0x7fffffff).toInt())
                .setMaxSize(720).setMaxFps(30).setVideoBitRate(8_000_000).setCodec("h264").setControl(true).build()
            val operation = when (mode) {
                "clipboard" -> ShellBridgeRequest.Operation.START_CLIPBOARD
                "panel" -> ShellBridgeRequest.Operation.START_PANEL
                else -> ShellBridgeRequest.Operation.START_SCRCPY
            }
            leaseStarted = true
            val result = requireNotNull(runtime).executeAuthenticated(peer, session, ShellBridgeRequest.newBuilder()
                .setRequestId(UUID.randomUUID().toString()).setLeaseId(lease).setBootGeneration(boot)
                .setOperation(operation).setPowerOn(false).setOptions(options).build())
            check(result.available && result.errorCode.isEmpty() && result.state == if (mode == "panel") "panel_off" else "ready")
            if (!owns()) { close("expired"); return }
            if (mode != "panel") {
                listener.bind(InetSocketAddress(InetAddress.getByAddress(byteArrayOf(127,0,0,1)), 0), 8)
                port = listener.localPort
                Thread({ accept() }, "shell-qa-loopback").start()
            }
            state = "prepared"
        } catch (_: Exception) { error = "typed_lease_start_failed"; close("failed") }
    }
    private fun accept() {
        while (!closed.get()) {
            val socket = try { listener.accept() } catch (_: Exception) { return }
            val admitted = synchronized(lock) { if (!owns() || clients.size >= 8) false else { clients.add(socket); true } }
            if (!admitted) { socket.close(); continue }
            try { workers.execute { serve(socket) } }
            catch (_: Exception) { synchronized(lock) { clients.remove(socket) }; socket.close() }
        }
    }
    private fun serve(socket: Socket) {
        try {
            socket.soTimeout = 3_000
            val input = DataInputStream(socket.getInputStream())
            val supplied = ByteArray(32).also(input::readFully)
            val valid = synchronized(secret) { MessageDigest.isEqual(secret, supplied) }; supplied.fill(0)
            if (!valid || !owns()) return
            val type = when (input.readUnsignedByte()) { 1 -> "video"; 2 -> "control"; 3 -> "clipboard"; else -> return }
            if ((mode == "scrcpy" && type !in setOf("video", "control")) ||
                (mode == "clipboard" && type !in setOf("control", "clipboard")) || mode == "panel") return
            socket.soTimeout = 0
            requireNotNull(runtime).bridgeAuthenticated(input, socket.getOutputStream(), peer, session, "$lease/$type") { closeSocket(socket) }
        } catch (_: Exception) { /* No user content or credentials in reports. */ }
        finally { synchronized(lock) { clients.remove(socket) }; closeSocket(socket) }
    }
    fun close(reason: String) {
        if (!closed.compareAndSet(false, true)) return
        state = "closing"
        runCatching { listener.close() }
        synchronized(lock) { clients.toList().forEach(::closeSocket); clients.clear() }
        synchronized(secret) { secret.fill(0) }
        // Expiry runs on this timer: self-interruption would abort the real
        // synchronous STOP receipt before it can confirm physical retirement.
        timer.shutdown(); workers.shutdownNow()
        if (leaseStarted && runtime?.status()?.bootGeneration == boot) runCatching {
            val stopped = requireNotNull(runtime).executeAuthenticated(peer, session, ShellBridgeRequest.newBuilder()
                .setRequestId(UUID.randomUUID().toString()).setLeaseId(lease).setBootGeneration(boot)
                .setOperation(ShellBridgeRequest.Operation.STOP).build())
            retirementConfirmed = stopped.available && stopped.errorCode.isEmpty() && stopped.state == "stopped"
            if (!retirementConfirmed) error = "typed_lease_retirement_unconfirmed"
        }
        if (wake.isHeld) runCatching { wake.release() }
        retirementFinished = true; state = reason
    }
    private fun closeSocket(socket: Socket) {
        runCatching { socket.shutdownInput() }; runCatching { socket.shutdownOutput() }; runCatching { socket.close() }
    }
    fun receipt() = JSONObject().put("state", state).put("error", error).put("mode", mode)
        .put("port", port).put("lease_id", lease).put("boot_generation", boot)
        .put("remaining_ms", (guard.deadline-SystemClock.elapsedRealtime()).coerceAtLeast(0))
        .put("wake_held", wake.isHeld).put("listener_closed", listener.isClosed)
        .put("retirement_finished", retirementFinished).put("retirement_confirmed", retirementConfirmed)
}
