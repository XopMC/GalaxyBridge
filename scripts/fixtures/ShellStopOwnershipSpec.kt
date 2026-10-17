package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import org.junit.Assert.*
import org.junit.Test

/** The completion block is extracted verbatim from executeAuthenticated(). */
private class ActualShellStopRuntime {
    val lock = Any()
    var owner: Any? = Any()
    val leases = ShellStreamLeaseRegistry()
    var removals = 0
    fun complete(peerID: String, sessionID: String, request: ShellBridgeRequest, response: ShellBridgeResult,
        boot: String, socket: Any? = owner, newLease: Boolean = false) {
        // ACTUAL_STOP_COMPLETION
    }
    private fun removeLeaseLocked(lease: String) { leases.remove(lease); removals++ }
}

class ShellStopOwnershipSpec {
    private val lease = "69830b65-6352-4b3a-8a21-70bcda45787e"
    private val boot = "f7ce5d25-497b-484f-bd5d-d1838a4d2978"
    private val requestID = "d5e1590c-47fb-4d73-9ac2-45988ba0a876"
    private fun request(id: String = requestID) = ShellBridgeRequest.newBuilder().setRequestId(id).setLeaseId(lease)
        .setBootGeneration(boot).setOperation(ShellBridgeRequest.Operation.STOP).build()
    private fun response(state: String = "stopped", error: String = "", available: Boolean = true, id: String = requestID) =
        ShellBridgeResult.newBuilder().setRequestId(id).setLeaseId(lease).setBootGeneration(boot)
            .setAvailable(available).setState(state).setErrorCode(error).build()
    private fun runtime() = ActualShellStopRuntime().also {
        assertTrue(it.leases.admit("peer", "session", lease))
        assertTrue(it.leases.declare("peer", "session", lease, listOf("$lease/video", "$lease/control")))
    }

    @Test fun failedOrUnknownStopRetainsOwnerForLaterConfirmedRetry() {
        for (reply in listOf(response("failed", "shell_operation_failed"), response("unknown"),
            response("stopped", "shell_operation_failed"), response(available = false),
            response().toBuilder().setLeaseId(boot).build(), response().toBuilder().addStreamIds("$lease/control").build())) {
            val runtime = runtime()
            runtime.complete("peer", "session", request(), reply, boot)
            assertTrue("A failed/unknown STOP must still pass the same-owner broker retry admission", runtime.leases.owns("peer", "session", lease))
            assertTrue(runtime.leases.allows("peer", "session", "$lease/control"))
            assertEquals(0, runtime.removals)
            val retryID = java.util.UUID.randomUUID().toString()
            runtime.complete("peer", "session", request(retryID), response(id = retryID), boot)
            assertFalse(runtime.leases.owns("peer", "session", lease))
            assertFalse(runtime.leases.allows("peer", "session", "$lease/control"))
            assertEquals(1, runtime.removals)
        }
    }

    @Test fun anotherPeerOrStaleSessionCannotRemoveCurrentOwnership() {
        for ((peer, session) in listOf("other" to "session", "peer" to "old-session")) {
            val runtime = runtime()
            runtime.complete(peer, session, request(), response(), boot)
            assertTrue(runtime.leases.owns("peer", "session", lease))
            assertEquals(0, runtime.removals)
        }
    }

    @Test fun staleControlGenerationOrRequestNeverReachesRemoval() {
        val runtime = runtime()
        val previousOwner = runtime.owner
        runtime.owner = Any()
        assertThrows(IllegalStateException::class.java) {
            runtime.complete("peer", "session", request(), response(), boot, socket = previousOwner)
        }
        assertThrows(IllegalStateException::class.java) {
            runtime.complete("peer", "session", request(), response().toBuilder().setBootGeneration("old-boot").build(), boot)
        }
        assertThrows(IllegalStateException::class.java) {
            runtime.complete("peer", "session", request(), response().toBuilder().setRequestId("old-request").build(), boot)
        }
        assertTrue(runtime.leases.owns("peer", "session", lease))
        assertEquals(0, runtime.removals)
    }
}
