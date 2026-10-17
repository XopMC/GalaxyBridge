package com.xopmc.galaxybridge.transport.shell
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import org.junit.Assert.*
import org.junit.Test

private class ActualFailureRuntime {
    val lock = Any()
    var owner: Any? = Any()
    val leases = ShellStreamLeaseRegistry()
    var deactivated = 0
    var generation = "f7ce5d25-497b-484f-bd5d-d1838a4d2978"
    fun fail(request: ShellBridgeRequest, socket: Any? = owner, newLease: Boolean = false,
        boot: String = generation, peerID: String = "peer", sessionID: String = "session",
        compositeLease: Boolean = leases.isComposite(peerID, sessionID, request.leaseId),
        failure: Exception = java.io.IOException()): ShellBridgeResult {
        // ACTUAL_EXECUTE_FAILURE
    }
    private fun removeLeaseLocked(lease: String) { leases.remove(lease) }
    private fun deactivateLocked() { deactivated++; owner = null; leases.clear() }
    private fun rejected(request: ShellBridgeRequest, reason: String): ShellBridgeResult = ShellBridgeResult.newBuilder()
        .setRequestId(request.requestId).setAvailable(false).setErrorCode(reason).build()
}
class ShellReadOnlyFailureIsolationSpec {
    private val lease = "69830b65-6352-4b3a-8a21-70bcda45787e"
    private fun runtime() = ActualFailureRuntime().also { assertTrue(it.leases.admit("peer", "session", lease)) }
    private fun request(operation: ShellBridgeRequest.Operation) = ShellBridgeRequest.newBuilder()
        .setRequestId("d5e1590c-47fb-4d73-9ac2-45988ba0a876").setLeaseId(lease).setOperation(operation).build()
    @Test fun uncertainCompositeCleanupPreservesSiblingCapturesAndExactRetryAuthority() {
        val runtime = runtime(); val owner = runtime.owner
        val id = "d5e1590c-47fb-4d73-9ac2-45988ba0a876"
        val stop = request(ShellBridgeRequest.Operation.STOP).toBuilder().setLeaseId(id)
            .setBootGeneration(runtime.generation).setDisplayStateStop(true).build()
        assertTrue(runtime.leases.admitCompositeStop("peer", "session", stop))
        runtime.fail(stop)
        assertSame(owner, runtime.owner); assertEquals(0, runtime.deactivated)
        assertTrue(runtime.leases.owns("peer", "session", lease))
        assertTrue(runtime.leases.isComposite("peer", "session", id))
        assertTrue(runtime.leases.admitCompositeStop("peer", "session", stop))
        val replaced = Any(); runtime.owner = replaced
        runtime.fail(stop, socket = owner)
        assertSame(replaced, runtime.owner); assertEquals(0, runtime.deactivated)
    }
    @Test fun optionalProofAndReadFailuresPreserveLiveSiblingCaptures() {
        for (operation in listOf(ShellBridgeRequest.Operation.STATUS, ShellBridgeRequest.Operation.VERIFY_RETIREMENT,
            ShellBridgeRequest.Operation.RELEASE_RETIRED_RESOURCE)) {
            val runtime = runtime(); val owner = runtime.owner
            val reply = runtime.fail(request(operation))
            assertSame("Optional/read failure must not revoke the broker lifetime owner", owner, runtime.owner)
            assertTrue(runtime.leases.owns("peer", "session", lease))
            assertFalse(reply.available); assertEquals("shell_request_failed", reply.errorCode)
        }
    }
    @Test fun ambiguousChildOperationStillRetiresOnlyItsOriginalLifetimeOwner() {
        for (operation in listOf(ShellBridgeRequest.Operation.START_SCRCPY, ShellBridgeRequest.Operation.STOP)) {
            val runtime = runtime(); runtime.fail(request(operation))
            assertNull(runtime.owner); assertEquals(1, runtime.deactivated)
            val replaced = runtime(); val old = replaced.owner; replaced.owner = Any()
            replaced.fail(request(operation), socket = old)
            assertNotNull(replaced.owner); assertEquals(0, replaced.deactivated)
        }
    }
}
