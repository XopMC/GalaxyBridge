package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.ChannelKind
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.OpenChannel
import com.xopmc.galaxybridge.protocol.v1.Ping
import com.xopmc.galaxybridge.protocol.v1.Pong
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompanionAuthenticatedChannelRoleTest {
    @Test fun featurePolicyCanOnlyUseTheAuthenticatedControlRole() {
        val request = Envelope.newBuilder().setFeatureConfigurationRequest(
            com.xopmc.galaxybridge.protocol.v1.FeatureConfigurationRequest.getDefaultInstance()).build()
        val control = CompanionAuthenticatedChannelRole()
        assertTrue(control.admit(open(ChannelKind.CHANNEL_KIND_CONTROL)))
        assertTrue(control.admit(request))
        for (kind in listOf(ChannelKind.CHANNEL_KIND_EVENTS, ChannelKind.CHANNEL_KIND_FILES, ChannelKind.CHANNEL_KIND_ENHANCED_STREAM)) {
            val auxiliary = CompanionAuthenticatedChannelRole()
            assertTrue(auxiliary.admit(open(kind)))
            assertFalse(auxiliary.admit(request))
            assertFalse(auxiliary.ownsControlRetirement)
        }
    }

    private fun open(kind: ChannelKind) = Envelope.newBuilder()
        .setOpenChannel(OpenChannel.newBuilder().setKind(kind)).build()

    @Test fun authenticatedProbeEofCannotRetireAnotherConnectionsLeases() {
        assertFalse(CompanionAuthenticatedChannelRole().ownsControlRetirement)
    }

    @Test fun failedAuxiliaryStreamCannotBecomeAControlOwner() {
        val role = CompanionAuthenticatedChannelRole()
        assertTrue(role.admit(open(ChannelKind.CHANNEL_KIND_ENHANCED_STREAM)))
        assertFalse(role.ownsControlRetirement)
        assertFalse(role.admit(Envelope.newBuilder().setPing(Ping.getDefaultInstance()).build()))
        assertFalse(role.ownsControlRetirement)
    }

    @Test fun dnsAndMediaChannelFailuresCannotRevokeControlLeases() {
        for (kind in listOf(ChannelKind.CHANNEL_KIND_INTERNET_PROXY, ChannelKind.CHANNEL_KIND_EVENTS,
            ChannelKind.CHANNEL_KIND_VIDEO, ChannelKind.CHANNEL_KIND_AUDIO, ChannelKind.CHANNEL_KIND_FILES,
            ChannelKind.CHANNEL_KIND_CAMERA)) {
            val role = CompanionAuthenticatedChannelRole()
            assertTrue(role.admit(open(kind)))
            assertFalse(kind.name, role.ownsControlRetirement)
        }
    }

    @Test fun legacyControlStartsWithHeartbeatWithoutOpenChannel() {
        val role = CompanionAuthenticatedChannelRole()
        assertTrue(role.admit(Envelope.newBuilder().setPing(Ping.getDefaultInstance()).build()))
        assertTrue(role.ownsControlRetirement)
        assertFalse(role.admit(open(ChannelKind.CHANNEL_KIND_ENHANCED_STREAM)))
        assertTrue(role.ownsControlRetirement)
    }

    @Test fun legacyControlMayStartWithAShellRequestBeforeItsFirstHeartbeat() {
        val role = CompanionAuthenticatedChannelRole()
        assertTrue(role.admit(Envelope.newBuilder().setShellBridgeRequest(
            ShellBridgeRequest.newBuilder().setOperation(ShellBridgeRequest.Operation.STATUS)).build()))
        assertTrue(role.ownsControlRetirement)
    }

    @Test fun explicitControlRetainsRetirementAuthority() {
        val role = CompanionAuthenticatedChannelRole()
        assertTrue(role.admit(open(ChannelKind.CHANNEL_KIND_CONTROL)))
        assertTrue(role.ownsControlRetirement)
    }

    @Test fun emptyAndPongRetainSafeUnsupportedResponsesWithoutClaimingControl() {
        for (incoming in listOf(Envelope.getDefaultInstance(),
            Envelope.newBuilder().setPong(Pong.getDefaultInstance()).build())) {
            val role = CompanionAuthenticatedChannelRole()
            assertTrue(role.admit(incoming))
            assertFalse(role.ownsControlRetirement)
        }
    }

    @Test fun unspecifiedAndUnknownChannelsNeverClaimControl() {
        for (incoming in listOf(open(ChannelKind.CHANNEL_KIND_UNSPECIFIED),
            Envelope.newBuilder().setOpenChannel(OpenChannel.newBuilder().setKindValue(999)).build())) {
            val role = CompanionAuthenticatedChannelRole()
            assertFalse(role.admit(incoming))
            assertFalse(role.ownsControlRetirement)
        }
    }
}
