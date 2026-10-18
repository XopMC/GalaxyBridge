package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import com.xopmc.galaxybridge.protocol.v1.CaptureRetirementQuery
import com.xopmc.galaxybridge.protocol.v1.DisplayStateCommand
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
        ShellBridgeRequest.Operation.START_PANEL, ShellBridgeRequest.Operation.START_DISPLAY_STATE,
        ShellBridgeRequest.Operation.STOP)
    fun valid(request: ShellBridgeRequest): Boolean {
        if (!uuid(request.requestId) || request.operation == ShellBridgeRequest.Operation.UNRECOGNIZED ||
            request.operation == ShellBridgeRequest.Operation.LIST_APPLICATIONS) return false
        if (request.displayStateStop && (request.operation != ShellBridgeRequest.Operation.STOP ||
                request.hasOptions() || request.powerOn || request.hasRetirement() || request.hasDisplayState())) return false
        if (request.hasDisplayState() && request.operation != ShellBridgeRequest.Operation.START_DISPLAY_STATE) return false
        if (request.operation == ShellBridgeRequest.Operation.VERIFY_RETIREMENT ||
            request.operation == ShellBridgeRequest.Operation.RELEASE_RETIRED_RESOURCE) {
            if (request.leaseId.isNotEmpty() || !uuid(request.bootGeneration) || request.powerOn ||
                request.hasOptions() || !request.hasRetirement()) return false
            val query = request.retirement
            if (request.operation == ShellBridgeRequest.Operation.RELEASE_RETIRED_RESOURCE) {
                if (query.kind !in setOf(CaptureRetirementQuery.Kind.DISPLAY_POWER_CONTROLLER,
                        CaptureRetirementQuery.Kind.DISPLAY_STATE_CONTROLLER) ||
                    !uuid(query.ownedResourceId) || query.resourceSha256.size() != 32) return false
            } else if (query.ownedResourceId.isNotEmpty() || !query.resourceSha256.isEmpty) return false
            return when (query.kind) {
                CaptureRetirementQuery.Kind.PROBE_SUPPORT -> query.scid == 0 && query.pid == 0 && query.processStartTicks == 0L
                CaptureRetirementQuery.Kind.SCRCPY_CAPTURE -> query.scid > 0 && query.pid == 0 && query.processStartTicks == 0L
                CaptureRetirementQuery.Kind.DISPLAY_POWER_CONTROLLER,
                CaptureRetirementQuery.Kind.DISPLAY_STATE_CONTROLLER -> query.scid == 0 && query.pid > 1 && query.processStartTicks > 0
                else -> false
            }
        }
        if (request.hasRetirement()) return false
        if (request.operation != ShellBridgeRequest.Operation.STATUS && (!uuid(request.leaseId) || !uuid(request.bootGeneration))) return false
        if (request.operation == ShellBridgeRequest.Operation.START_DISPLAY_STATE) {
            if (!request.hasDisplayState() || request.hasOptions() || request.powerOn) return false
            val command = request.displayState
            if (command.panelPolicy == DisplayStateCommand.PanelPolicy.UNRECOGNIZED) return false
            return when (command.action) {
                DisplayStateCommand.Action.SNAPSHOT,
                DisplayStateCommand.Action.STATUS -> !command.interactive && command.revision == 0L &&
                    command.panelPolicy == DisplayStateCommand.PanelPolicy.PRESERVE
                DisplayStateCommand.Action.APPLY -> command.revision > 0
                else -> false
            }
        }
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
    fun admitCompositeStop(peer: String, session: String, request: ShellBridgeRequest): Boolean {
        if (!ShellBridgePolicy.valid(request) || request.operation != ShellBridgeRequest.Operation.STOP || !request.displayStateStop ||
            request.leaseId in retiredComposite || request.leaseId in retiredProducers) return false
        val old = entry(request.leaseId)
        if (old != null) {
            if (old.peer != peer || old.session != session || !old.composite ||
                compositeStops[request.leaseId]?.boot?.let { it != request.bootGeneration } == true) return false
            old.draining = true
            return true
        }
        // Cleanup cannot require a free producer slot. This separate bounded
        // pool carries no streams and seals delayed SNAPSHOT/APPLY admission.
        if (compositeStops.size >= 32 || compositeIdentityCount() >= 4096) return false
        compositeStops[request.leaseId] = CompositeStop(Lease(peer, session, composite = true, draining = true), request.bootGeneration)
        return true
    }
    private data class Lease(val peer: String, val session: String, val composite: Boolean = false,
        val streams: MutableSet<String> = mutableSetOf(), var snapshotConfirmed: Boolean = false,
        var policyAttempted: Boolean = false, var draining: Boolean = false)
    private val leases = linkedMapOf<String, Lease>()
    private data class CompositeStop(val lease: Lease, val boot: String)
    private val compositeStops = linkedMapOf<String, CompositeStop>()
    private fun entry(id: String): Lease? = leases[id] ?: compositeStops[id]?.lease
    private fun compositeIdentityCount(): Int = retiredComposite.size + retiredProducers.size + leases.size + compositeStops.size
    private data class RetiredComposite(val peer: String, val session: String, val receipt: ShellBridgeResult? = null)
    private val retiredComposite = linkedMapOf<String, RetiredComposite>()
    private val retiredProducers = linkedMapOf<String, RetiredComposite>()
    fun admit(peer: String, session: String, lease: String): Boolean {
        if (!ShellBridgePolicy.uuid(lease) || lease in retiredComposite || lease in retiredProducers || lease in compositeStops) return false
        leases[lease]?.let { return it.peer == peer && it.session == session && !it.composite && !it.draining }
        if (leases.size >= 8 || compositeIdentityCount() >= 4096) return false
        leases[lease] = Lease(peer, session)
        return true
    }
    fun admitComposite(peer: String, session: String, request: ShellBridgeRequest): Boolean {
        if (!ShellBridgePolicy.valid(request) || request.operation != ShellBridgeRequest.Operation.START_DISPLAY_STATE ||
            request.leaseId in retiredComposite || request.leaseId in retiredProducers || request.leaseId in compositeStops) return false
        val old = leases[request.leaseId]
        if (request.displayState.action == DisplayStateCommand.Action.SNAPSHOT) {
            if (old != null) return old.peer == peer && old.session == session && old.composite && !old.draining && !old.policyAttempted
            if (leases.size >= 8 || compositeIdentityCount() >= 4096) return false
            leases[request.leaseId] = Lease(peer, session, composite = true)
            return true
        }
        if (old == null || old.peer != peer || old.session != session || !old.composite || old.draining || !old.snapshotConfirmed) return false
        if (request.displayState.action == DisplayStateCommand.Action.APPLY) old.policyAttempted = true
        return true
    }
    fun confirmCompositeSnapshot(peer: String, session: String, lease: String, result: ShellBridgeResult): Boolean {
        val entry = leases[lease] ?: return false
        if (!isComposite(peer, session, lease) || entry.draining || entry.policyAttempted ||
            result.leaseId != lease || !result.available || result.errorCode.isNotEmpty() ||
            result.state != "display_state_snapshotted" || result.streamIdsCount != 0 ||
            result.displayStateAcknowledgement.isEmpty || result.displayStateAcknowledgement.size() > 8192) return false
        entry.snapshotConfirmed = true
        return true
    }
    fun canWriteComposite(peer: String, session: String, request: ShellBridgeRequest): Boolean {
        if (!ShellBridgePolicy.valid(request) || request.operation != ShellBridgeRequest.Operation.START_DISPLAY_STATE ||
            !isComposite(peer, session, request.leaseId)) return false
        val entry = leases[request.leaseId] ?: return false
        if (entry.draining) return false
        return when (request.displayState.action) {
            DisplayStateCommand.Action.SNAPSHOT -> !entry.policyAttempted
            DisplayStateCommand.Action.STATUS -> entry.snapshotConfirmed
            DisplayStateCommand.Action.APPLY -> entry.snapshotConfirmed && entry.policyAttempted
            else -> false
        }
    }
    fun markCompositeStopping(peer: String, session: String, lease: String): Boolean {
        if (!isComposite(peer, session, lease)) return false
        entry(lease)!!.draining = true
        return true
    }
    fun markProducerStopping(peer: String, session: String, lease: String): Boolean {
        val entry = leases[lease] ?: return false
        if (entry.peer != peer || entry.session != session || entry.composite) return false
        entry.draining = true
        return true
    }
    fun canWriteProducer(peer: String, session: String, lease: String): Boolean = leases[lease]?.let {
        it.peer == peer && it.session == session && !it.composite && !it.draining
    } == true
    fun retainProducerRetirement(peer: String, session: String, lease: String, result: ShellBridgeResult): Boolean {
        if (isComposite(peer, session, lease) || !confirmsStopped(peer, session, lease, result) ||
            !ShellBridgePolicy.uuid(result.bootGeneration)) return false
        retiredProducers[lease] = RetiredComposite(peer, session, result)
        return true
    }
    fun cachedProducerStop(peer: String, session: String, request: ShellBridgeRequest): ShellBridgeResult? {
        if (!ShellBridgePolicy.valid(request) || request.operation != ShellBridgeRequest.Operation.STOP || request.displayStateStop) return null
        val retired = retiredProducers[request.leaseId] ?: return null
        val receipt = retired.receipt ?: return null
        if (retired.peer != peer || retired.session != session || receipt.bootGeneration != request.bootGeneration) return null
        return receipt.toBuilder().setRequestId(request.requestId).build()
    }
    fun isComposite(peer: String, session: String, lease: String): Boolean =
        entry(lease)?.let { it.peer == peer && it.session == session && it.composite } == true
    fun retainCompositeRetirement(peer: String, session: String, lease: String, result: ShellBridgeResult): Boolean {
        if (!isComposite(peer, session, lease) || !confirmsStopped(peer, session, lease, result) ||
            !ShellBridgePolicy.uuid(result.bootGeneration) ||
            compositeStops[lease]?.boot?.let { it != result.bootGeneration } == true) return false
        retiredComposite[lease]?.let { return it.peer == peer && it.session == session && it.receipt == result }
        retiredComposite[lease] = RetiredComposite(peer, session, result)
        return true
    }
    fun cachedCompositeStop(peer: String, session: String, request: ShellBridgeRequest): ShellBridgeResult? {
        if (!ShellBridgePolicy.valid(request) || request.operation != ShellBridgeRequest.Operation.STOP) return null
        val retired = retiredComposite[request.leaseId] ?: return null
        val receipt = retired.receipt ?: return null
        if (retired.peer != peer || retired.session != session || receipt.bootGeneration != request.bootGeneration) return null
        return receipt.toBuilder().setRequestId(request.requestId).build()
    }
    fun hasAnyLease(): Boolean = leases.isNotEmpty() || compositeStops.isNotEmpty()
    fun owns(peer: String, session: String, lease: String): Boolean = entry(lease)?.let { it.peer == peer && it.session == session } == true
    fun confirmsStopped(peer: String, session: String, lease: String, result: ShellBridgeResult): Boolean {
        if (!owns(peer, session, lease) || result.leaseId != lease || !result.available || result.errorCode.isNotEmpty() || result.streamIdsCount != 0) return false
        val entry = entry(lease) ?: return false
        if (!entry.composite) return result.state == "stopped"
        if (result.displayStateAcknowledgement.size() > 8192) return false
        if (result.state == "display_state_not_started") return !entry.policyAttempted && !result.hasRetirementProof()
        if (result.state != "display_state_retired" || !result.hasRetirementProof()) return false
        val proof = result.retirementProof
        return proof.kind == CaptureRetirementQuery.Kind.DISPLAY_STATE_CONTROLLER && proof.supported && proof.absent &&
            proof.scid == 0 && proof.pid > 1 && proof.processStartTicks > 0 && proof.panelsCount == 0 &&
            proof.displayStateSnapshot.size() <= 8192 && proof.displayStateTerminalAcknowledgement.size() <= 8192 &&
            (!proof.displayStateSnapshot.isEmpty || !proof.displayStateTerminalAcknowledgement.isEmpty)
    }
    fun declare(peer: String, session: String, lease: String, streams: List<String>): Boolean {
        val entry = leases[lease] ?: return false
        if (!owns(peer, session, lease) || entry.draining || streams.size > 4 || streams.toSet().size != streams.size ||
            streams.any { ShellBridgePolicy.stream(it)?.first != lease }) return false
        if (entry.composite && streams.isNotEmpty()) return false
        entry.streams.clear(); entry.streams.addAll(streams)
        return true
    }
    fun allows(peer: String, session: String, stream: String): Boolean = ShellBridgePolicy.stream(stream)?.let { (lease, _) ->
        leases[lease]?.let { it.peer == peer && it.session == session && !it.composite && !it.draining && stream in it.streams } == true
    } == true
    // Producers are created after the shared display owner, but must retire
    // before it. Stable sorting retains the existing producer cleanup order.
    fun owned(peer: String, session: String): List<String> = (leases + compositeStops.mapValues { it.value.lease }).entries
        .filter { it.value.peer == peer && it.value.session == session }
        .sortedBy { it.value.composite }.map { it.key }
    fun remove(lease: String) {
        (leases.remove(lease) ?: compositeStops.remove(lease)?.lease)?.let {
            if (it.composite && lease !in retiredComposite) retiredComposite[lease] = RetiredComposite(it.peer, it.session)
        }
    }
    fun clear() { leases.clear(); compositeStops.clear(); retiredComposite.clear(); retiredProducers.clear() }
}
