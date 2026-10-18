package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.Ping
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class CompanionControlIntakeTest {
    private fun operation() = Envelope.newBuilder().setDeviceId("host").setSessionId("session")
        .setShellBridgeRequest(ShellBridgeRequest.newBuilder().setRequestId("start")).build()
    private fun ping() = Envelope.newBuilder().setDeviceId("host").setSessionId("session").setMessageId(17)
        .setPing(Ping.newBuilder().setMonotonicTimeNs(123456)).build()

    @Test fun actualIntakeAnswersMatchingPongWhileCommandAndInternetRenewalAreBlocked() {
        val operationStarted = CountDownLatch(1)
        val renewalStarted = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val pong = CountDownLatch(1)
        val intake = CompanionControlIntake("phone", authorized = { true }, dispatch = {
            operationStarted.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS))
        }, renew = {
            renewalStarted.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS))
        }, writeFrame = {
            val response = Envelope.parseFrom(it)
            assertEquals("phone", response.deviceId); assertEquals("session", response.sessionId)
            assertEquals(18L, response.messageId); assertEquals(123456L, response.pong.echoedMonotonicTimeNs)
            pong.countDown()
        }, failed = { throw AssertionError(it) })
        try {
            assertTrue(intake.admit(operation())); assertTrue(operationStarted.await(1, TimeUnit.SECONDS))
            assertTrue(intake.admit(ping())); assertTrue(renewalStarted.await(1, TimeUnit.SECONDS))
            assertTrue(pong.await(200, TimeUnit.MILLISECONDS))
        } finally { intake.closeAdmission(); unblock.countDown(); intake.awaitSettled() }
    }

    @Test fun rawChannelHandoffIsNeverAdmittedToControlWorker() {
        val intake = CompanionControlIntake("phone", authorized = { true }, dispatch = { fail("raw channel dispatched") },
            renew = {}, writeFrame = {}, failed = {})
        try {
            assertFalse(intake.admit(Envelope.newBuilder().setOpenChannel(
                com.xopmc.galaxybridge.protocol.v1.OpenChannel.getDefaultInstance()).build()))
        } finally { intake.closeAdmission(); intake.awaitSettled() }
    }

    @Test fun closedIntakeRejectsBothCommandsAndPongs() {
        val intake = CompanionControlIntake("phone", authorized = { true }, dispatch = { fail("closed") },
            renew = { fail("closed") }, writeFrame = { fail("closed") }, failed = {})
        intake.closeAdmission(); intake.awaitSettled()
        assertFalse(intake.admit(operation())); assertFalse(intake.admit(ping()))
    }

    @Test fun queuedEnableTakesEffectBeforeFeatureCheckOfFollowingStart() {
        val enableStarted = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val startExecuted = CountDownLatch(1)
        val featureEnabled = AtomicBoolean(false)
        val enable = Envelope.newBuilder().setFeatureConfigurationRequest(
            com.xopmc.galaxybridge.protocol.v1.FeatureConfigurationRequest.getDefaultInstance()).build()
        val intake = CompanionControlIntake("phone", authorized = { true }, featureAllowed = {
            it.hasFeatureConfigurationRequest() || featureEnabled.get()
        }, featureRejected = { fail("ordered enable must precede START feature check") }, dispatch = {
            if (it.hasFeatureConfigurationRequest()) {
                enableStarted.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS)); featureEnabled.set(true)
            } else startExecuted.countDown()
        }, renew = {}, writeFrame = {}, failed = { throw AssertionError(it) })
        try {
            assertTrue(intake.admit(enable)); assertTrue(enableStarted.await(1, TimeUnit.SECONDS))
            assertTrue(intake.admit(operation())); unblock.countDown()
            assertTrue(startExecuted.await(1, TimeUnit.SECONDS))
        } finally { intake.closeAdmission(); unblock.countDown(); intake.awaitSettled() }
    }

    @Test fun phonePolicyRevocationIsRecheckedAtExecutionRatherThanAdmission() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val rejected = CountDownLatch(1)
        val enabled = AtomicBoolean(true)
        val intake = CompanionControlIntake("phone", authorized = { true }, featureAllowed = { enabled.get() },
            featureRejected = { rejected.countDown() }, dispatch = {
                started.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS))
            }, renew = {}, writeFrame = {}, failed = { throw AssertionError(it) })
        try {
            intake.admit(operation()); assertTrue(started.await(1, TimeUnit.SECONDS)); intake.admit(operation())
            enabled.set(false); unblock.countDown(); assertTrue(rejected.await(1, TimeUnit.SECONDS))
        } finally { intake.closeAdmission(); unblock.countDown(); intake.awaitSettled() }
    }
}
