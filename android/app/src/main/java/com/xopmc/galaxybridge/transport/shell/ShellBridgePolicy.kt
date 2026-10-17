package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import com.xopmc.galaxybridge.protocol.v1.CaptureRetirementQuery
import java.util.UUID

internal object ShellBridgePolicy {
    fun uuid(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
    fun allowedDistribution(packageName: String, distribution: String): Boolean =
        (packageName == "com.xopmc.galaxybridge" && distribution == "direct") ||
            (packageName == "com.xopmc.galaxybridge.internal" && distribution == "internal")
    fun activation(socket: String, token: String, generation: String): Boolean =
        socket.matches(Regex("[A-Za-z0-9._-]{8,96}")) && token.matches(Regex("[a-f0-9]{64}")) && uuid(generation)
    fun readOnly(operation: ShellBridgeRequest.Operation): Boolean =
        operation == ShellBridgeRequest.Operation.STATUS || operation == ShellBridgeRequest.Operation.VERIFY_RETIREMENT
    fun usesChildLease(operation: ShellBridgeRequest.Operation): Boolean = operation in setOf(
        ShellBridgeRequest.Operation.START_SCRCPY, ShellBridgeRequest.Operation.START_CLIPBOARD,
        ShellBridgeRequest.Operation.START_PANEL, ShellBridgeRequest.Operation.STOP)
    fun valid(request: ShellBridgeRequest): Boolean {
        if (!uuid(request.requestId) || request.operation == ShellBridgeRequest.Operation.UNRECOGNIZED ||
            request.operation == ShellBridgeRequest.Operation.LIST_APPLICATIONS) return false
        if (request.operation == ShellBridgeRequest.Operation.VERIFY_RETIREMENT ||
            request.operation == ShellBridgeRequest.Operation.RELEASE_RETIRED_RESOURCE) {
            if (request.leaseId.isNotEmpty() || !uuid(request.bootGeneration) || request.powerOn ||
                request.hasOptions() || !request.hasRetirement()) return false
            val query = request.retirement
            if (request.operation == ShellBridgeRequest.Operation.RELEASE_RETIRED_RESOURCE) {
                if (query.kind != CaptureRetirementQuery.Kind.DISPLAY_POWER_CONTROLLER ||
                    !uuid(query.ownedResourceId) || query.resourceSha256.size() != 32) return false
            } else if (query.ownedResourceId.isNotEmpty() || !query.resourceSha256.isEmpty) return false
            return when (query.kind) {
                CaptureRetirementQuery.Kind.PROBE_SUPPORT -> query.scid == 0 && query.pid == 0 && query.processStartTicks == 0L
                CaptureRetirementQuery.Kind.SCRCPY_CAPTURE -> query.scid > 0 && query.pid == 0 && query.processStartTicks == 0L
                CaptureRetirementQuery.Kind.DISPLAY_POWER_CONTROLLER -> query.scid == 0 && query.pid > 1 && query.processStartTicks > 0
                else -> false
            }
        }
        if (request.hasRetirement()) return false
        if (request.operation != ShellBridgeRequest.Operation.STATUS && (!uuid(request.leaseId) || !uuid(request.bootGeneration))) return false
        val o = request.options
        return o.scid >= 0 && o.displayId >= 0 &&
            (o.packageName.isEmpty() || o.packageName.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+"))) &&
            o.codec in setOf("", "h264", "h265", "av1") &&
            (o.maxSize == 0 || o.maxSize in 64..8192) && (o.maxFps == 0 || o.maxFps in 1..240) &&
            (o.videoBitRate == 0L || o.videoBitRate in 100_000..100_000_000L) &&
            ((o.width == 0 && o.height == 0) || (o.width in 64..8192 && o.height in 64..8192))
    }
    fun stream(value: String): Pair<String, String>? {
        val fields = value.split('/')
        if (fields.size != 2 || !uuid(fields[0]) || fields[1] !in setOf("video", "audio", "control", "clipboard", "log")) return null
        return fields[0] to fields[1]
    }
}

internal class ShellStreamLeaseRegistry {
    private data class Lease(val peer: String, val session: String, val streams: MutableSet<String> = mutableSetOf())
    private val leases = linkedMapOf<String, Lease>()
    fun admit(peer: String, session: String, lease: String): Boolean {
        if (!ShellBridgePolicy.uuid(lease)) return false
        leases[lease]?.let { return it.peer == peer && it.session == session }
        if (leases.size >= 8) return false
        leases[lease] = Lease(peer, session)
        return true
    }
    fun hasAnyLease(): Boolean = leases.isNotEmpty()
    fun owns(peer: String, session: String, lease: String): Boolean = leases[lease]?.let { it.peer == peer && it.session == session } == true
    fun confirmsStopped(peer: String, session: String, lease: String, result: ShellBridgeResult): Boolean =
        owns(peer, session, lease) && result.leaseId == lease && result.available && result.errorCode.isEmpty() &&
            result.state == "stopped" && result.streamIdsCount == 0
    fun declare(peer: String, session: String, lease: String, streams: List<String>): Boolean {
        if (!owns(peer, session, lease) || streams.size > 4 || streams.toSet().size != streams.size ||
            streams.any { ShellBridgePolicy.stream(it)?.first != lease }) return false
        leases.getValue(lease).streams.clear(); leases.getValue(lease).streams.addAll(streams)
        return true
    }
    fun allows(peer: String, session: String, stream: String): Boolean = ShellBridgePolicy.stream(stream)?.let { (lease, _) ->
        owns(peer, session, lease) && stream in leases.getValue(lease).streams
    } == true
    fun owned(peer: String, session: String): List<String> = leases.filterValues { it.peer == peer && it.session == session }.keys.toList()
    fun remove(lease: String) { leases.remove(lease) }
    fun clear() { leases.clear() }
}
