package com.xopmc.galaxybridge.transport.shell

import com.google.protobuf.ByteString
import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.os.SystemClock
import android.os.Trace
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/** No process launch here. The separately ADB-activated shell-UID owner accepts typed verbs only. */
class ShellBridgeRuntime(private val context: Context, private val isForegroundOwner: () -> Boolean) : AutoCloseable {
    private val lock = Any()
    private val writeLock = Any()
    private var owner: ShellFDChannel? = null
    private var connectingOwner: ShellFDChannel? = null
    private var activationRevision = UUID.randomUUID()
    private var activationID = ""
    private val tickets = ShellActivationTicketPolicy()
    private val ownerLifetime = Binder()
    private var bridgeBinder: IBinder? = null
    private var bridgeDeath: IBinder.DeathRecipient? = null
    private var activationState = "unavailable"
    private var activationError = ""
    private var token = ""
    private var generation = ""
    private var runtimeSHA256 = ByteString.EMPTY
    private var closed = false
    private val pending = linkedMapOf<String, CompletableFuture<ShellBridgeResult>>()
    private val leases = ShellStreamLeaseRegistry()
    private data class Stream(val lease: String, val socket: ShellFDChannel, val cancel: () -> Unit)
    private val streams = linkedMapOf<String, Stream>()
    private data class OpeningStream(val lease: String, val attempt: UUID, val cancel: () -> Unit)
    private val openingStreams = linkedMapOf<String, OpeningStream>()
    private val relay = ThreadPoolExecutor(32, 32, 30, TimeUnit.SECONDS, ArrayBlockingQueue(32), ThreadPoolExecutor.AbortPolicy())

    val isAvailable: Boolean get() = synchronized(lock) { !closed && isForegroundOwner() && owner != null && bridgeBinder?.isBinderAlive == true }
    fun status(): ShellBridgeResult = synchronized(lock) {
        ShellBridgeResult.newBuilder().setBootGeneration(generation).setAvailable(isAvailable)
            .setRuntimeSha256(if (isAvailable) runtimeSHA256 else ByteString.EMPTY)
            .setState(if (isAvailable) "ready" else activationState).setErrorCode(if (isAvailable || activationState in setOf("prepared", "attaching")) "" else activationError.ifEmpty { "shell_bridge_not_activated" }).build()
    }

    /** Only the DUMP-protected prepare receiver authorizes a one-use shell attachment. */
    fun prepare(name: String, secret: String, bootGeneration: String): ShellBridgeResult = synchronized(lock) {
        // Global admission and replacement share this lock. A preceding idle
        // status on any Mac cannot authorize revoking another peer's new lease.
        if (leases.hasAnyLease() || pending.isNotEmpty() || openingStreams.isNotEmpty() ||
            streams.isNotEmpty() || connectingOwner != null || (bridgeBinder != null && owner == null) ||
            tickets.isPreparing(SystemClock.elapsedRealtime())) {
            return@synchronized ShellBridgeResult.newBuilder().setBootGeneration(bootGeneration)
                .setAvailable(false).setState("busy").setErrorCode("shell_runtime_in_use").build()
        }
        deactivateLocked()
        val allowed = ShellBridgePolicy.allowedDistribution(context.packageName, BuildConfig.DISTRIBUTION)
        check(tickets.prepare(name, secret, bootGeneration, SystemClock.elapsedRealtime(), !closed && isForegroundOwner(), allowed) != null) { "shell_prepare_rejected" }
        activationID = name; token = secret; generation = bootGeneration
        activationState = "prepared"; activationError = ""
        status()
    }

    /** Provider has checked shell UID and DUMP before reading its attach bundle. */
    fun attach(callerUID: Int, name: String, secret: String, bootGeneration: String, bridge: IBinder): ShellBridgeResult {
        val claim: ShellActivationTicketPolicy.Claim
        val attempt: UUID
        synchronized(lock) {
            val allowed = ShellBridgePolicy.allowedDistribution(context.packageName, BuildConfig.DISTRIBUTION)
            claim = requireNotNull(tickets.consume(callerUID, name, secret, bootGeneration,
                SystemClock.elapsedRealtime(), !closed && isForegroundOwner(), allowed)) { "shell_attach_rejected" }
            attempt = activationRevision
            bridgeBinder = bridge; activationState = "attaching"; activationError = ""
            val death = IBinder.DeathRecipient {
                synchronized(lock) { if (bridgeBinder === bridge && activationRevision == attempt) deactivateLocked() }
            }
            bridgeDeath = death
            try { bridge.linkToDeath(death, 0) } catch (_: Exception) { deactivateLocked(); throw java.io.IOException("shell_binder_dead") }
        }
        var channel: ShellFDChannel? = null
        var stage = ShellActivationStage.CONNECT
        try {
            val socket = ShellBinderEndpoint.open(bridge, bootGeneration, secret, lifetime = ownerLifetime) {
                synchronized(lock) { closed || !isForegroundOwner() || activationRevision != attempt || bridgeBinder !== bridge || !tickets.isCurrent(claim) }
            }.also { channel = it }
            synchronized(lock) {
                check(!closed && isForegroundOwner() && activationRevision == attempt && bridgeBinder === bridge && tickets.isCurrent(claim))
                connectingOwner = socket
            }
            stage = ShellActivationStage.TIMEOUT
            socket.timeout(5_000)
            stage = ShellActivationStage.OWNER_WRITE
            ShellBridgeWire.write(socket.output, JSONObject().put("kind", "owner").put("token", secret).put("boot_generation", bootGeneration).toString())
            stage = ShellActivationStage.OWNER_READ
            val ready = result(JSONObject(ShellBridgeWire.read(socket.input)))
            stage = ShellActivationStage.READY_CHECK
            check(ready.available && ready.bootGeneration == bootGeneration && ready.errorCode.isEmpty()) { "shell_owner_rejected" }
            stage = ShellActivationStage.TIMEOUT
            socket.timeout(0)
            stage = ShellActivationStage.PROMOTE
            synchronized(lock) {
                check(!closed && isForegroundOwner() && activationRevision == attempt && bridgeBinder === bridge && tickets.isCurrent(claim))
                owner = socket; connectingOwner = null; activationState = "ready"; activationError = ""
                runtimeSHA256 = ready.runtimeSha256
            }
            Thread({ readOwner(socket, bootGeneration) }, "GalaxyBridge-shell-owner").apply { isDaemon = true; start() }
            return ready
        } catch (error: Exception) {
            val failure = ShellActivationFailure(stage, error)
            synchronized(lock) {
                if (activationRevision == attempt && bridgeBinder === bridge) {
                    deactivateLocked()
                    generation = bootGeneration; activationState = "failed"; activationError = ShellActivationDiagnostics.publicCode(failure)
                }
            }
            channel?.close()
            throw failure
        }
    }

    fun executeAuthenticated(peerID: String, sessionID: String, request: ShellBridgeRequest): ShellBridgeResult {
        val completion = CompletableFuture<ShellBridgeResult>()
        val socket: ShellFDChannel
        val boot: String
        var newLease = false
        var compositeLease = false
        synchronized(lock) {
            if (!isAvailable) return rejected(request, "shell_bridge_not_activated")
            if (!ShellBridgePolicy.valid(request)) return rejected(request, "shell_request_invalid")
            if (request.bootGeneration.isNotEmpty() && request.bootGeneration != generation) return rejected(request, "shell_boot_generation_changed")
            if (request.requestId in pending) return rejected(request, "shell_request_busy")
            leases.cachedCompositeStop(peerID, sessionID, request)?.let { return it }
            leases.cachedProducerStop(peerID, sessionID, request)?.let { return it }
            if (pending.size >= 32) return rejected(request, "shell_request_busy")
            if (ShellBridgePolicy.usesChildLease(request.operation)) {
                if (request.operation == ShellBridgeRequest.Operation.STOP) {
                    if (request.displayStateStop && !leases.admitCompositeStop(peerID, sessionID, request)) {
                        return rejected(request, "shell_lease_kind_or_owner")
                    }
                    if (!leases.owns(peerID, sessionID, request.leaseId)) return rejected(request, "shell_lease_unknown")
                    compositeLease = leases.isComposite(peerID, sessionID, request.leaseId)
                    if (compositeLease) check(leases.markCompositeStopping(peerID, sessionID, request.leaseId))
                    else check(leases.markProducerStopping(peerID, sessionID, request.leaseId))
                } else {
                    newLease = !leases.owns(peerID, sessionID, request.leaseId)
                    val admitted = if (request.operation == ShellBridgeRequest.Operation.START_DISPLAY_STATE)
                        leases.admitComposite(peerID, sessionID, request) else leases.admit(peerID, sessionID, request.leaseId)
                    if (!admitted) return rejected(request, "shell_lease_limit_or_owner")
                    compositeLease = leases.isComposite(peerID, sessionID, request.leaseId)
                }
            }
            socket = requireNotNull(owner); boot = generation
            pending[request.requestId] = completion
        }
        try {
            val command = requestJSON(request, boot, compositeStop = compositeLease && request.operation == ShellBridgeRequest.Operation.STOP)
            synchronized(writeLock) {
                val writable = synchronized(lock) {
                    check(owner === socket && generation == boot)
                    when {
                        request.operation == ShellBridgeRequest.Operation.START_DISPLAY_STATE -> leases.canWriteComposite(peerID, sessionID, request)
                        ShellBridgePolicy.usesChildLease(request.operation) && request.operation != ShellBridgeRequest.Operation.STOP ->
                            leases.canWriteProducer(peerID, sessionID, request.leaseId)
                        else -> true
                    }
                }
                if (!writable) return rejected(request, "shell_lease_draining")
                try { ShellBridgeWire.write(socket.output, command.toString()) }
                catch (channelFailure: java.io.IOException) {
                    synchronized(lock) { if (owner === socket && generation == boot) deactivateLocked() }
                    throw channelFailure
                }
            }
            val response = completion.get(if (compositeLease) 20 else 10, TimeUnit.SECONDS)
            synchronized(lock) {
                check(owner === socket && response.bootGeneration == boot && response.requestId == request.requestId)
                if (request.operation == ShellBridgeRequest.Operation.STOP) {
                    // A failed bounded retirement still owns its child. Keep
                    // exact peer/session authority so a later STOP can retry.
                    if (leases.confirmsStopped(peerID, sessionID, request.leaseId, response)) {
                        if (compositeLease) check(leases.retainCompositeRetirement(peerID, sessionID, request.leaseId, response))
                        else check(leases.retainProducerRetirement(peerID, sessionID, request.leaseId, response))
                        removeLeaseLocked(request.leaseId)
                    }
                }
                else if (ShellBridgePolicy.usesChildLease(request.operation)) {
                    // A successful concurrent STOP may already have retired
                    // this lease. Its late startup reply cannot affect siblings.
                    if (!leases.owns(peerID, sessionID, request.leaseId)) return rejected(request, "shell_lease_retired")
                    if (response.available && response.errorCode.isEmpty()) {
                        if (!compositeLease && !leases.canWriteProducer(peerID, sessionID, request.leaseId))
                            return rejected(request, "shell_lease_draining")
                        if (request.operation == ShellBridgeRequest.Operation.START_DISPLAY_STATE &&
                            request.displayState.action == com.xopmc.galaxybridge.protocol.v1.DisplayStateCommand.Action.SNAPSHOT &&
                            leases.canWriteComposite(peerID, sessionID, request)) {
                            check(leases.confirmCompositeSnapshot(peerID, sessionID, request.leaseId, response)) { "shell_invalid_display_snapshot" }
                        }
                        check(leases.declare(peerID, sessionID, request.leaseId, response.streamIdsList)) { "shell_invalid_stream_declaration" }
                    } else if (newLease && !compositeLease) {
                        // Failed startup may still own a partially started
                        // native child. Preserve its STOP authority until proof.
                        leases.markProducerStopping(peerID, sessionID, request.leaseId)
                    }
                }
            }
            return response
        } catch (failure: Exception) {
            // A callback from an old socket/boot cannot remove a lease from
            // the replacement owner, even if the caller reused an identifier.
            synchronized(lock) {
                if (owner === socket && generation == boot &&
                    (!ShellBridgePolicy.usesChildLease(request.operation) || leases.owns(peerID, sessionID, request.leaseId))) {
                    if (compositeLease) {
                        // A local timeout/validation failure is not owner EOF.
                        // Keep the exact uncertain lease for a typed STOP retry.
                        leases.markCompositeStopping(peerID, sessionID, request.leaseId)
                    } else {
                        if (newLease) removeLeaseLocked(request.leaseId)
                        if (ShellBridgePolicy.usesChildLease(request.operation)) deactivateLocked()
                    }
                }
            }
            if (failure is InterruptedException) Thread.currentThread().interrupt()
            return rejected(request, "shell_request_failed")
        } finally { synchronized(lock) { if (pending[request.requestId] === completion) pending.remove(request.requestId) } }
    }

    /** The control lease owns children. Closing one media socket does not revoke siblings. */
    fun retireAuthenticated(peerID: String, sessionID: String) {
        val (owned, boot) = synchronized(lock) { leases.owned(peerID, sessionID) to generation }
        owned.forEach { lease ->
            executeAuthenticated(peerID, sessionID, ShellBridgeRequest.newBuilder().setRequestId(UUID.randomUUID().toString())
                .setLeaseId(lease).setBootGeneration(boot).setOperation(ShellBridgeRequest.Operation.STOP).build())
        }
    }

    fun bridgeAuthenticated(input: InputStream, output: OutputStream, peerID: String, sessionID: String, streamID: String,
        cancel: () -> Unit) {
        var local: ShellFDChannel? = null
        var readinessSent = false
        val openingAttempt = UUID.randomUUID()
        try {
            val (lease, type) = requireNotNull(ShellBridgePolicy.stream(streamID))
            val config = synchronized(lock) {
                check(isAvailable && streams.size + openingStreams.size < 32 && streamID !in streams && streamID !in openingStreams && leases.allows(peerID, sessionID, streamID)) { "shell_stream_not_owned" }
                openingStreams[streamID] = OpeningStream(lease, openingAttempt, cancel)
                Triple(requireNotNull(bridgeBinder), token, generation)
            }
            val socket = ShellBinderEndpoint.open(config.first, config.third, config.second, streamID = streamID) {
                synchronized(lock) { !isAvailable || bridgeBinder !== config.first || generation != config.third || openingStreams[streamID]?.attempt != openingAttempt || !leases.allows(peerID, sessionID, streamID) }
            }.also { local = it }
            synchronized(lock) {
                check(isAvailable && bridgeBinder === config.first && generation == config.third && openingStreams[streamID]?.attempt == openingAttempt && streamID !in streams && leases.allows(peerID, sessionID, streamID))
                openingStreams.remove(streamID)
                streams[streamID] = Stream(lease, socket, cancel)
            }
            socket.timeout(5_000)
            ShellBridgeWire.write(socket.output, JSONObject().put("kind", "stream").put("token", config.second)
                .put("boot_generation", config.third).put("lease_id", lease).put("stream_type", type).toString())
            val ready = result(JSONObject(ShellBridgeWire.read(socket.input)))
            check(ready.available && ready.errorCode.isEmpty() && ready.bootGeneration == config.third && ready.leaseId == lease)
            synchronized(lock) {
                check(isAvailable && generation == config.third && leases.allows(peerID, sessionID, streamID) && streams[streamID]?.socket === socket)
            }
            val envelope = Envelope.newBuilder().setProtocolMajor(1).setDeviceId(com.xopmc.galaxybridge.security.DeviceIdStore.getOrCreate(context))
                .setSessionId(sessionID).setShellBridgeResult(ready).build().toByteArray()
            DataOutputStream(output).apply { writeInt(envelope.size); write(envelope); flush() }
            readinessSent = true
            socket.timeout(0)
            val upload = relay.submit { try { pump(input, socket.output, "$type/macToPhone") } finally { runCatching { socket.shutdownOutput() } } }
            try { pump(socket.input, output, "$type/phoneToMac") } finally { upload.cancel(true) }
        } catch (_: Exception) {
            if (!readinessSent) runCatching {
                val failure = Envelope.newBuilder().setProtocolMajor(1).setSessionId(sessionID)
                    .setShellBridgeResult(ShellBridgeResult.newBuilder().setBootGeneration(generation)
                        .setAvailable(false).setState("failed").setErrorCode("shell_stream_unavailable")).build().toByteArray()
                DataOutputStream(output).apply { writeInt(failure.size); write(failure); flush() }
            }
            // Root channel close/error is terminal; never fall back to a public port or shell command.
        } finally {
            synchronized(lock) {
                if (streams[streamID]?.socket === local) streams.remove(streamID)
                if (openingStreams[streamID]?.attempt == openingAttempt) openingStreams.remove(streamID)
            }
            closeChannel(local); runCatching(cancel)
        }
    }

    private fun closeChannel(socket: ShellFDChannel?) { socket?.close() }

    private fun readOwner(socket: ShellFDChannel, boot: String) {
        try {
            while (true) {
                val response = result(JSONObject(ShellBridgeWire.read(socket.input)))
                check(response.bootGeneration == boot)
                synchronized(lock) { if (owner !== socket) return; pending[response.requestId]?.complete(response) }
            }
        } catch (_: Exception) { synchronized(lock) { if (owner === socket) deactivateLocked() } }
    }
    private fun requestJSON(request: ShellBridgeRequest, boot: String, compositeStop: Boolean = false): JSONObject {
        val json = JSONObject()
        ShellBridgeCommandWire.fields(request, boot, compositeStop).forEach { (key, value) ->
            val field = if (value is Map<*, *>) JSONObject().apply {
                value.forEach { (name, item) -> check(name is String); put(name, item) }
            } else value
            json.put(key, field)
        }
        return json
    }
    private fun result(json: JSONObject): ShellBridgeResult {
        val builder = ShellBridgeResult.newBuilder().setRequestId(json.optString("request_id"))
            .setLeaseId(json.optString("lease_id")).setBootGeneration(json.getString("boot_generation"))
            .setAvailable(json.getBoolean("available")).setState(json.optString("state"))
            .setErrorCode(json.optString("error_code"))
            .setRuntimeSha256(ByteString.copyFrom(ShellRuntimeIdentity.decode(json.optString("runtime_sha256", ""))))
        fun payload(value: JSONObject): ByteString {
            val bytes = value.toString().toByteArray(Charsets.UTF_8)
            check(bytes.size in 1..8192) { "shell_display_state_payload_limit" }
            return ByteString.copyFrom(bytes)
        }
        json.optJSONObject("display_state_acknowledgement")?.let { builder.setDisplayStateAcknowledgement(payload(it)) }
        json.optJSONArray("stream_ids")?.let { array -> check(array.length() <= 4); repeat(array.length()) { builder.addStreamIds(array.getString(it)) } }
        json.optJSONObject("retirement_proof")?.let { proof ->
            val kind = proof.getInt("kind")
            val scid = proof.getLong("scid")
            val pid = proof.getLong("pid")
            val start = proof.getLong("process_start_ticks")
            check(kind in 0..3 && scid in 0..0x7fffffffL && pid in 0..0x7fffffffL && start >= 0)
            val typed = com.xopmc.galaxybridge.protocol.v1.CaptureRetirementProof.newBuilder()
                .setKindValue(kind).setScid(scid.toInt()).setPid(pid.toInt()).setProcessStartTicks(start)
                .setSupported(proof.getBoolean("supported")).setAbsent(proof.getBoolean("absent"))
            val resourceID = proof.optString("owned_resource_id")
            check(resourceID.isEmpty() || ShellBridgePolicy.uuid(resourceID))
            typed.setOwnedResourceId(resourceID).setResourceRemoved(proof.optBoolean("resource_removed", false))
            val ids = hashSetOf<String>()
            proof.optJSONArray("panels")?.let { panels ->
                check(panels.length() <= 8)
                repeat(panels.length()) {
                    val panel = panels.getJSONObject(it)
                    val id = panel.getString("physical_id")
                    check(id.matches(Regex("0|[1-9][0-9]{0,19}")) &&
                        java.lang.Long.toUnsignedString(java.lang.Long.parseUnsignedLong(id)) == id && ids.add(id))
                    typed.addPanels(com.xopmc.galaxybridge.protocol.v1.PhysicalPanelPowerState.newBuilder()
                        .setPhysicalId(id).setOn(panel.getBoolean("on")))
                }
            }
            check(kind != 3 || typed.panelsCount == 0) { "shell_composite_proof_cannot_use_boolean_panels" }
            proof.optJSONObject("display_state_snapshot")?.let { typed.setDisplayStateSnapshot(payload(it)) }
            proof.optJSONObject("display_state_terminal_acknowledgement")?.let { typed.setDisplayStateTerminalAcknowledgement(payload(it)) }
            builder.setRetirementProof(typed)
        }
        return builder.build()
    }
    private fun rejected(request: ShellBridgeRequest, error: String) = ShellBridgeResult.newBuilder()
        .setRequestId(request.requestId).setLeaseId(request.leaseId).setBootGeneration(generation).setAvailable(isAvailable)
        .setState("failed").setErrorCode(error).build()
    private fun pump(input: InputStream, output: OutputStream, traceRole: String) {
        val buffer = ByteArray(64 * 1024)
        while (!Thread.currentThread().isInterrupted) {
            // Atrace is off normally. Labels contain only the allowlisted
            // stream kind, direction and byte count, never stream IDs or data.
            val tracing = Trace.isEnabled()
            if (tracing) Trace.beginSection("GBRelay/$traceRole/read")
            val count = try { input.read(buffer) } finally { if (tracing) Trace.endSection() }
            if (count < 0) return
            if (count == 0) continue
            if (tracing) Trace.beginSection("GBRelay/$traceRole/write/$count")
            try {
                output.write(buffer, 0, count)
                output.flush()
            } finally {
                if (tracing) Trace.endSection()
            }
        }
    }
    private fun removeLeaseLocked(lease: String) {
        leases.remove(lease)
        openingStreams.filterValues { it.lease == lease }.values.toList().forEach { runCatching(it.cancel) }
        openingStreams.entries.removeAll { it.value.lease == lease }
        streams.filterValues { it.lease == lease }.values.toList().forEach { closeChannel(it.socket); runCatching(it.cancel) }
        streams.entries.removeAll { it.value.lease == lease }
    }
    private fun deactivateLocked() {
        tickets.revoke()
        activationRevision = UUID.randomUUID()
        val binder = bridgeBinder; val death = bridgeDeath; bridgeBinder = null; bridgeDeath = null
        if (binder != null && death != null) runCatching { binder.unlinkToDeath(death, 0) }
        activationState = "unavailable"; activationError = ""
        val opening = connectingOwner; connectingOwner = null
        closeChannel(opening)
        val previous = owner; owner = null
        closeChannel(previous)
        pending.values.forEach { it.completeExceptionally(IllegalStateException("shell_owner_closed")) }; pending.clear()
        openingStreams.values.toList().forEach { runCatching(it.cancel) }; openingStreams.clear()
        streams.values.toList().forEach { closeChannel(it.socket); runCatching(it.cancel) }; streams.clear(); leases.clear()
        activationID = ""; token = ""; generation = ""; runtimeSHA256 = ByteString.EMPTY
    }
    fun deactivate() = synchronized(lock) { deactivateLocked() }
    override fun close() = synchronized(lock) { closed = true; deactivateLocked(); relay.shutdownNow(); Unit }
}
