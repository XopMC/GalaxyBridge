package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.DisplayStateCommand
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import org.junit.Assert.*
import org.junit.Test

internal class ActualCompositeAdmission(val leases: ShellStreamLeaseRegistry = ShellStreamLeaseRegistry()) {
    val pending = mutableSetOf<String>()
    val lock = Any()
    val owner = Any()
    var generation = "f7ce5d25-497b-484f-bd5d-d1838a4d2978"
    fun writable(peerID: String, sessionID: String, request: ShellBridgeRequest,
                 boot: String = generation, socket: Any = owner): Boolean {
        // ACTUAL_WRITE_ADMISSION
        return writable
    }
    fun admit(peerID: String, sessionID: String, request: ShellBridgeRequest): ShellBridgeResult {
        var newLease = false
        var compositeLease = false
        // ACTUAL_CACHED_ADMISSION
        // ACTUAL_CHILD_ADMISSION
        return ShellBridgeResult.newBuilder().setAvailable(true).setState(if (compositeLease) "composite" else "legacy").build()
    }
    private fun rejected(request: ShellBridgeRequest, error: String): ShellBridgeResult = ShellBridgeResult.newBuilder()
        .setRequestId(request.requestId).setAvailable(false).setErrorCode(error).build()
}

class ShellCompositeStopAdmissionSpec {
    private val boot = "f7ce5d25-497b-484f-bd5d-d1838a4d2978"
    private val id = "69830b65-6352-4b3a-8a21-70bcda45787e"
    private fun stop() = ShellBridgeRequest.newBuilder().setRequestId(boot).setLeaseId(id).setBootGeneration(boot)
        .setOperation(ShellBridgeRequest.Operation.STOP).setDisplayStateStop(true).build()
    private fun snapshot() = stop().toBuilder().clearDisplayStateStop().setOperation(ShellBridgeRequest.Operation.START_DISPLAY_STATE)
        .setDisplayState(DisplayStateCommand.getDefaultInstance()).build()
    @Test fun legacyStopSealsPreviouslyAdmittedButNotYetWrittenStartup() {
        val runtime = ActualCompositeAdmission()
        val start = stop().toBuilder().clearDisplayStateStop().setOperation(ShellBridgeRequest.Operation.START_SCRCPY).build()
        assertTrue(runtime.admit("peer", "session", start).available)
        assertTrue(runtime.writable("peer", "session", start))
        assertTrue(runtime.admit("peer", "session", stop().toBuilder().clearDisplayStateStop().build()).available)
        assertFalse(runtime.writable("peer", "session", start))
        assertFalse(runtime.admit("peer", "session", start).available)
        assertFalse(runtime.leases.allows("peer", "session", "$id/control"))
    }
    @Test fun cachedFreshIDBypassesCapacityButCannotReuseAnInflightRequestID() {
        val runtime = ActualCompositeAdmission()
        assertTrue(runtime.leases.admitCompositeStop("peer", "session", stop()))
        val receipt = ShellBridgeResult.newBuilder().setRequestId(boot).setLeaseId(id).setBootGeneration(boot)
            .setAvailable(true).setState("display_state_not_started").build()
        assertTrue(runtime.leases.retainCompositeRetirement("peer", "session", id, receipt))
        runtime.leases.remove(id)
        runtime.pending.add(boot)
        val busy = runtime.admit("peer", "session", stop())
        assertFalse(busy.available); assertEquals("shell_request_busy", busy.errorCode)
        assertEquals(setOf(boot), runtime.pending)
        runtime.pending.clear(); repeat(32) { runtime.pending.add(java.util.UUID.randomUUID().toString()) }
        val retry = stop().toBuilder().setRequestId(java.util.UUID.randomUUID().toString()).build()
        val cached = runtime.admit("peer", "session", retry)
        assertTrue(cached.available); assertEquals(retry.requestId, cached.requestId)
        assertEquals(32, runtime.pending.size)
        assertEquals(receipt, runtime.leases.cachedCompositeStop("peer", "session", stop()))
    }
    @Test fun typedStopOvertakesHelperAdmissionWithoutTouchingEightSiblingProducers() {
        val runtime = ActualCompositeAdmission()
        val siblings = (0..7).map { java.util.UUID.randomUUID().toString() }
        siblings.forEach { assertTrue(runtime.leases.admit("peer", "session", it)) }
        assertFalse(runtime.admit("peer", "session", stop().toBuilder().clearDisplayStateStop().build()).available)
        assertEquals("composite", runtime.admit("peer", "session", stop()).state)
        assertFalse(runtime.admit("peer", "session", snapshot()).available)
        assertFalse(runtime.admit("other", "session", stop()).available)
        siblings.forEach { assertTrue(runtime.leases.owns("peer", "session", it)) }
    }
    @Test fun typedStopAfterHelperAdmissionSealsTheNotYetWrittenNativeStartup() {
        val runtime = ActualCompositeAdmission()
        assertEquals("composite", runtime.admit("peer", "session", snapshot()).state)
        assertTrue(runtime.leases.canWriteComposite("peer", "session", snapshot()))
        assertEquals("composite", runtime.admit("peer", "session", stop()).state)
        assertFalse(runtime.leases.canWriteComposite("peer", "session", snapshot()))
        assertFalse(runtime.admit("peer", "session", snapshot()).available)
    }
}
