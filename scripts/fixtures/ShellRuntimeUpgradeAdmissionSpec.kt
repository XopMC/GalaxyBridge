package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import org.junit.Assert.*
import org.junit.Test

private object SystemClock { var now = 1_000L; fun elapsedRealtime() = now }
private object BuildConfig { const val DISTRIBUTION = "direct" }
private class Context { val packageName = "com.xopmc.galaxybridge" }
private class ActualRuntimePreparation {
    val lock = Any()
    private val context = Context()
    val tickets = ShellActivationTicketPolicy()
    var closed = false
    var owner: Any? = Any()
    var connectingOwner: Any? = null
    var bridgeBinder: Any? = null
    val leases = ShellStreamLeaseRegistry()
    val pending = linkedMapOf<String, Any>()
    val streams = linkedMapOf<String, Any>()
    val openingStreams = linkedMapOf<String, Any>()
    var activationID = "old-activation"
    var token = "old-token"
    var generation = "11111111-1111-4111-8111-111111111111"
    var activationState = "ready"
    var activationError = ""
    var deactivations = 0
    fun isForegroundOwner() = true
    fun status(): ShellBridgeResult = ShellBridgeResult.newBuilder().setAvailable(owner != null)
        .setBootGeneration(generation).setState(activationState).setErrorCode(activationError).build()
    fun deactivateLocked() {
        deactivations++; owner = null; tickets.revoke(); leases.clear()
        pending.clear(); streams.clear(); openingStreams.clear()
    }
    fun prepare(name: String, secret: String, bootGeneration: String): ShellBridgeResult = synchronized(lock) {
        // ACTUAL_RUNTIME_PREPARE
    }
}
class ShellRuntimeUpgradeAdmissionSpec {
    private val boot = "22222222-2222-4222-8222-222222222222"
    private val name = "gb_shell_" + "a".repeat(32)
    private val token = "b".repeat(64)
    private val lease = "33333333-3333-4333-8333-333333333333"
    @Test fun anotherPeerOrLateStartMustNotBeDeactivated() {
        for (peer in listOf("this-mac", "another-mac")) {
            val r = ActualRuntimePreparation()
            // An idle observation is followed by admission before prepare takes the lock.
            assertTrue(r.leases.owned(peer, "session").isEmpty())
            assertTrue(r.leases.admit(peer, "session", lease))
            val result = r.prepare(name, token, boot)
            assertEquals("Global lease must survive automatic replacement", 0, r.deactivations)
            assertTrue(r.leases.owns(peer, "session", lease))
            assertEquals("11111111-1111-4111-8111-111111111111", r.generation)
            assertEquals("shell_runtime_in_use", result.errorCode)
        }
    }
    @Test fun uncertainOperationsAndOpeningOrActiveStreamsAreAlsoBusy() {
        for (kind in 0..4) {
            val r = ActualRuntimePreparation()
            when (kind) {
                0 -> r.pending["uncertain-start"] = Any()
                1 -> r.openingStreams["opening"] = Any()
                2 -> r.streams["active"] = Any()
                3 -> r.connectingOwner = Any()
                else -> { r.owner = null; r.bridgeBinder = Any() }
            }
            assertEquals("shell_runtime_in_use", r.prepare(name, token, boot).errorCode)
            assertEquals(0, r.deactivations)
            if (kind != 4) assertNotNull(r.owner)
        }
    }
    @Test fun preparationTicketCannotBeOverwrittenBeforeItsOriginalDeadline() {
        SystemClock.now = 1_000
        val r = ActualRuntimePreparation(); r.owner = null
        assertNotNull(r.tickets.prepare(name, token, boot, 1_000, true, true))
        assertEquals("shell_runtime_in_use", r.prepare(name, token, boot).errorCode)
        assertEquals(0, r.deactivations)
        assertNotNull(r.tickets.consume(2000, name, token, boot, 1_001, true, true))
    }
    @Test fun genuinelyIdleRuntimeOrExpiredTicketCanBePrepared() {
        for (expired in listOf(false, true)) {
            val r = ActualRuntimePreparation()
            if (expired) {
                assertNotNull(r.tickets.prepare(name, token, boot, 0, true, true))
                SystemClock.now = 10_000
            } else SystemClock.now = 1_000
            val result = r.prepare(name, token, boot)
            assertEquals(1, r.deactivations)
            assertFalse(result.available)
            assertEquals("prepared", result.state)
            assertEquals(boot, result.bootGeneration)
            assertNotNull(r.tickets.consume(2000, name, token, boot, SystemClock.now + 1, true, true))
        }
    }
}
