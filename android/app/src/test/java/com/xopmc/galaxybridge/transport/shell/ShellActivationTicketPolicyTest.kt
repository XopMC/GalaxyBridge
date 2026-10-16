package com.xopmc.galaxybridge.transport.shell

import org.junit.Assert.*
import org.junit.Test

class ShellActivationTicketPolicyTest {
    private val activation = "gb_shell_" + "a".repeat(32)
    private val otherActivation = "gb_shell_" + "b".repeat(32)
    private val token = "1".repeat(64)
    private val otherToken = "2".repeat(64)
    private val boot = "11111111-2222-3333-4444-555555555555"
    private val otherBoot = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    private fun prepare(policy: ShellActivationTicketPolicy, now: Long = 1_000) =
        policy.prepare(activation, token, boot, now, true, true)
    private fun consume(policy: ShellActivationTicketPolicy, now: Long = 1_001, uid: Int = 2000,
        id: String = activation, secret: String = token, generation: String = boot,
        foreground: Boolean = true, distribution: Boolean = true) =
        policy.consume(uid, id, secret, generation, now, foreground, distribution)

    @Test fun onlyShellUidMayEnterTheProviderBeforeReadingExtras() {
        assertTrue(ShellActivationTicketPolicy.admitsCaller(2000))
        for (uid in listOf(-1, 0, 1000, 10_000, 102_000)) assertFalse(ShellActivationTicketPolicy.admitsCaller(uid))
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        assertNull(consume(policy, uid = 10_000))
        assertNotNull(consume(policy))
    }

    @Test fun attachmentRequiresAPreparedTicketAndConsumesItOnlyOnce() {
        val policy = ShellActivationTicketPolicy()
        assertNull(consume(policy))
        assertNotNull(prepare(policy))
        val claim = requireNotNull(consume(policy))
        assertTrue(policy.isCurrent(claim))
        assertNull(consume(policy))
        assertTrue(policy.isCurrent(claim))
    }

    @Test fun fixedTenSecondDeadlineAdmitsBeforeAndRejectsAtExpiry() {
        val before = ShellActivationTicketPolicy()
        assertNotNull(prepare(before))
        assertNotNull(consume(before, now = 10_999))
        val expired = ShellActivationTicketPolicy()
        assertNotNull(prepare(expired))
        assertNull(consume(expired, now = 11_000))
        assertNull(consume(expired, now = 11_001))
    }

    @Test fun retriesAndWrongSecretsNeverExtendThePreparedDeadline() {
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        assertNull(consume(policy, now = 10_999, secret = otherToken))
        assertNull(consume(policy, now = 11_000))
    }

    @Test fun exactActivationSecretAndBootAreBoundWithoutBurningOnMismatch() {
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        assertNull(consume(policy, id = otherActivation))
        assertNull(consume(policy, secret = otherToken))
        assertNull(consume(policy, generation = otherBoot))
        assertNull(consume(policy, secret = "1".repeat(63)))
        assertNull(consume(policy, secret = "1".repeat(63) + "z"))
        assertNotNull(consume(policy))
    }

    @Test fun newerPrepareInvalidatesBothOldTicketAndInFlightAttachClaim() {
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        val old = requireNotNull(consume(policy))
        assertNotNull(policy.prepare(otherActivation, otherToken, otherBoot, 2_000, true, true))
        assertFalse(policy.isCurrent(old))
        assertNull(consume(policy, now = 2_001))
        val current = requireNotNull(consume(policy, now = 2_001, id = otherActivation, secret = otherToken, generation = otherBoot))
        assertTrue(policy.isCurrent(current))
    }

    @Test fun identicalMetadataCannotReviveAnOldClaimAfterReprepareAba() {
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        val old = requireNotNull(consume(policy))
        assertNotNull(prepare(policy, now = 2_000))
        val replacement = requireNotNull(consume(policy, now = 2_001))
        assertFalse(policy.isCurrent(old))
        assertTrue(policy.isCurrent(replacement))
    }

    @Test fun revokeClosesAdmissionAndInvalidatesInFlightWork() {
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        val old = requireNotNull(consume(policy))
        policy.revoke()
        assertFalse(policy.isCurrent(old))
        assertNull(consume(policy))
    }

    @Test fun foregroundAndDistributionGateBothPreparationAndConsumption() {
        for ((foreground, distribution) in listOf(false to true, true to false)) {
            val policy = ShellActivationTicketPolicy()
            assertNull(policy.prepare(activation, token, boot, 1_000, foreground, distribution))
            assertNull(consume(policy))
            assertNotNull(prepare(policy))
            assertNull(consume(policy, foreground = foreground, distribution = distribution))
            assertNull(consume(policy))
        }
    }

    @Test fun invalidReplacementInvalidatesPriorWorkAndCannotLeaveOldTicketActive() {
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        val claim = requireNotNull(consume(policy))
        assertNull(policy.prepare("bad", token, boot, 2_000, true, true))
        assertFalse(policy.isCurrent(claim))
        assertNull(consume(policy, now = 2_001))
    }

    @Test fun malformedActivationMetadataAndClockReversalFailClosed() {
        val policy = ShellActivationTicketPolicy()
        assertNull(policy.prepare(activation, "invalid-secret", boot, 1_000, true, true))
        assertNull(policy.prepare(activation, token, "not-a-uuid", 1_000, true, true))
        assertNull(prepare(policy, now = -1))
        assertNotNull(prepare(policy))
        assertNull(consume(policy, now = 999))
        assertNull(consume(policy, now = 1_001))
    }

    @Test fun concurrentAttachHasOneWinnerAndReplaysCannotInvalidateItsClaim() {
        val policy = ShellActivationTicketPolicy()
        assertNotNull(prepare(policy))
        val start = java.util.concurrent.CountDownLatch(1)
        val claims = java.util.Collections.synchronizedList(mutableListOf<ShellActivationTicketPolicy.Claim>())
        val workers = (0 until 8).map {
            Thread { start.await(); consume(policy)?.let(claims::add) }.apply { start() }
        }
        start.countDown()
        workers.forEach { it.join(2_000); assertFalse(it.isAlive) }
        assertEquals(1, claims.size)
        assertTrue(policy.isCurrent(claims.single()))
    }
}
