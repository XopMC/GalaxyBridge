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
    fun fail(request: ShellBridgeRequest, socket: Any? = owner, newLease: Boolean = false): ShellBridgeResult {
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
        .setRequestId("request").setOperation(operation).build()
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
