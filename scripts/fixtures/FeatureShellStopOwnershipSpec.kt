package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

private data class FeatureEnvelope(val deviceId: String = "peer", val sessionId: String = "session")
private class FeatureStopBroker(val response: ShellBridgeResult) {
    @Suppress("UNUSED_PARAMETER")
    fun executeAuthenticated(peer: String, session: String, request: ShellBridgeRequest) =
        response.toBuilder().setRequestId(request.requestId).build()
}

/** All three cleanup bodies and the lease record are copied verbatim from the server. */
private class ActualFeatureStopServer {
    // ACTUAL_FEATURE_LEASE
    val featureShellLeases = java.util.concurrent.ConcurrentHashMap<String, FeatureShellLease>()
    fun stop(shellRequest: ShellBridgeRequest, result: ShellBridgeResult, envelope: FeatureEnvelope) {
        // ACTUAL_FEATURE_STOP
    }
    fun disable(lease: FeatureShellLease, shell: FeatureStopBroker?) {
        // ACTUAL_FEATURE_DISABLE
    }
    fun cancelLateStart(result: ShellBridgeResult, lease: FeatureShellLease, bridge: FeatureStopBroker?, envelope: FeatureEnvelope) {
        // ACTUAL_LATE_START_DISABLE
    }
}

class FeatureShellStopOwnershipSpec {
    private val requestID = "8bf0babc-10a8-4c30-ab6f-8c7b13306b20"
    private val leaseID = "69830b65-6352-4b3a-8a21-70bcda45787e"
    private val boot = "f7ce5d25-497b-484f-bd5d-d1838a4d2978"
    private fun lease() = ActualFeatureStopServer.FeatureShellLease("peer", "session", leaseID, boot,
        setOf("screen"), setOf("$leaseID/video", "$leaseID/control"))
    private fun request() = ShellBridgeRequest.newBuilder().setRequestId(requestID)
        .setLeaseId(leaseID).setBootGeneration(boot).setOperation(ShellBridgeRequest.Operation.STOP).build()
    private fun reply() = ShellBridgeResult.newBuilder().setRequestId(requestID)
        .setLeaseId(leaseID).setBootGeneration(boot).setAvailable(true).setState("stopped").build()
    private fun invalidReplies() = listOf(
        reply().toBuilder().setAvailable(false).build(),
        reply().toBuilder().setState("failed").setErrorCode("shell_operation_failed").build(),
        reply().toBuilder().setState("unknown").build(),
        reply().toBuilder().setErrorCode("retirement_unconfirmed").build(),
        reply().toBuilder().setLeaseId(boot).build(),
        reply().toBuilder().setBootGeneration(leaseID).build(),
        reply().toBuilder().addStreamIds("$leaseID/control").build(),
    )
    private fun server() = ActualFeatureStopServer().also { it.featureShellLeases[leaseID] = lease() }
    private fun invoke(server: ActualFeatureStopServer, lane: Int, result: ShellBridgeResult?,
        old: ActualFeatureStopServer.FeatureShellLease = lease()) {
        when (lane) {
            0 -> server.stop(request(), requireNotNull(result), FeatureEnvelope())
            1 -> server.disable(old, result?.let(::FeatureStopBroker))
            2 -> server.cancelLateStart(reply(), old, result?.let(::FeatureStopBroker), FeatureEnvelope())
        }
    }

    @Test fun ordinaryStopKeepsUnconfirmedLeaseForRetry() {
        for (result in invalidReplies()) {
            val server = server()
            invoke(server, 0, result)
            assertEquals("Unconfirmed public STOP must keep feature ownership", lease(), server.featureShellLeases[leaseID])
            invoke(server, 0, reply())
            assertFalse(server.featureShellLeases.containsKey(leaseID))
        }
    }
    @Test fun disablingAFeatureKeepsUnconfirmedLeaseForRetry() {
        for (result in invalidReplies() + listOf(null)) {
            val server = server()
            invoke(server, 1, result)
            assertEquals("Feature disable must retain ownership until STOP is confirmed", lease(), server.featureShellLeases[leaseID])
            invoke(server, 1, reply())
            assertFalse(server.featureShellLeases.containsKey(leaseID))
        }
    }
    @Test fun lateStartCancellationKeepsUnconfirmedLeaseForRetry() {
        for (result in invalidReplies() + listOf(null)) {
            val server = server()
            invoke(server, 2, result)
            assertEquals("A late start must retain ownership until STOP is confirmed", lease(), server.featureShellLeases[leaseID])
            invoke(server, 2, reply())
            assertFalse(server.featureShellLeases.containsKey(leaseID))
        }
    }
    @Test fun confirmedStopRetiresAllThreePaths() {
        for (lane in 0..2) {
            val server = server()
            invoke(server, lane, reply())
            assertFalse(server.featureShellLeases.containsKey(leaseID))
        }
    }
    @Test fun foreignPeerAndSessionCannotRemoveFeatureOwnership() {
        for (envelope in listOf(FeatureEnvelope(deviceId = "other"), FeatureEnvelope(sessionId = "previous"))) {
            val server = server()
            server.stop(request(), reply(), envelope)
            assertEquals(lease(), server.featureShellLeases[leaseID])
        }
    }
    @Test fun lateStopCannotRemoveAReplacementLease() {
        for (lane in 0..2) {
            val server = server()
            val replacement = lease().copy(bootGeneration = UUID.randomUUID().toString())
            server.featureShellLeases[leaseID] = replacement
            invoke(server, lane, reply())
            assertEquals("Stale cleanup must not retire a replacement", replacement, server.featureShellLeases[leaseID])
        }
    }
}
