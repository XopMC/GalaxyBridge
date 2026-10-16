package com.xopmc.galaxybridge.internet

import org.junit.Assert.*
import org.junit.Test

class InternetGatewayPolicyTest {
    @Test fun wifiPreferredThenCellularAndNoDirectLocalOrVpnFallback() {
        val wifi = UpstreamCandidate(1, UpstreamKind.WIFI, true)
        val cellular = UpstreamCandidate(2, UpstreamKind.CELLULAR, true)
        assertEquals(wifi, UpstreamSelectionPolicy.select(listOf(cellular, wifi), null))
        assertEquals(cellular, UpstreamSelectionPolicy.select(listOf(wifi.copy(validated = false), cellular), null))
        assertNull(UpstreamSelectionPolicy.select(listOf(UpstreamCandidate(3, UpstreamKind.OTHER, true)), null))
    }

    @Test fun activeVpnMustBeSelectedInsteadOfBypassingThroughWifi() {
        val wifi = UpstreamCandidate(1, UpstreamKind.WIFI, true)
        val vpn = UpstreamCandidate(3, UpstreamKind.VPN, true)
        assertEquals(vpn, UpstreamSelectionPolicy.select(listOf(wifi, vpn), wifi.handle, vpn.handle))
    }

    @Test fun unavailableRequiredVpnNeverFallsBackToPhysicalNetwork() {
        val wifi = UpstreamCandidate(1, UpstreamKind.WIFI, true)
        val vpn = UpstreamCandidate(3, UpstreamKind.VPN, false)
        assertNull(UpstreamSelectionPolicy.select(listOf(wifi, vpn), wifi.handle, vpn.handle))
        assertNull(UpstreamSelectionPolicy.select(listOf(wifi), wifi.handle, vpn.handle))
    }

    @Test fun vpnNotApplyingToThisAppDoesNotOverrideItsPhysicalUpstream() {
        val wifi = UpstreamCandidate(1, UpstreamKind.WIFI, true)
        val unrelatedVpn = UpstreamCandidate(3, UpstreamKind.VPN, true)
        assertEquals(wifi, UpstreamSelectionPolicy.select(listOf(unrelatedVpn, wifi), null))
    }

    @Test fun unknownDefaultDuringVpnTransitionNeverSelectsPhysicalFallback() {
        val wifi = UpstreamCandidate(1, UpstreamKind.WIFI, true)
        assertNull(UpstreamSelectionPolicy.select(listOf(wifi), wifi.handle, defaultNetworkKnown = false))
        assertNull(UpstreamSelectionPolicy.select(listOf(wifi), wifi.handle, requiredVpn = 3, defaultNetworkKnown = false))
        assertEquals(wifi, UpstreamSelectionPolicy.select(listOf(wifi), null, defaultNetworkKnown = true))
    }

    @Test fun vpnBoundaryRetiresEarlierExplicitSocketsButPhysicalChangesKeepFlowAffinity() {
        val wifi = UpstreamCandidate(1, UpstreamKind.WIFI, true)
        val cellular = UpstreamCandidate(2, UpstreamKind.CELLULAR, true)
        val vpn = UpstreamCandidate(3, UpstreamKind.VPN, true)
        assertTrue(UpstreamSelectionPolicy.requiresRetirement(wifi, vpn))
        assertTrue(UpstreamSelectionPolicy.requiresRetirement(vpn, wifi))
        assertTrue(UpstreamSelectionPolicy.requiresRetirement(vpn, vpn.copy(handle = 4)))
        assertFalse(UpstreamSelectionPolicy.requiresRetirement(vpn, vpn))
        assertFalse(UpstreamSelectionPolicy.requiresRetirement(wifi, cellular))
    }

    @Test fun leaseIsPeerSessionBoundExpiresAndStopRevokesIt() {
        val leases = InternetLeaseRegistry(now = { 100L })
        val lease = leases.enable("peer", "session", 60_000)
        assertTrue(leases.admits("peer", "session", lease.id))
        assertFalse(leases.admits("other", "session", lease.id))
        assertFalse(leases.admits("peer", "old", lease.id))
        leases.revoke("peer", "session")
        assertFalse(leases.admits("peer", "session", lease.id))
        var clock = 100L
        val expiring = InternetLeaseRegistry(now = { clock })
        val expired = expiring.enable("peer", "session", 1)
        clock = 102L
        assertFalse(expiring.admits("peer", "session", expired.id))
        assertFalse(expiring.hasActive())
    }
    @Test fun leaseReplacementNeverAdmitsOldSessionAndTwoPeerLimitIsBounded() {
        val registry = InternetLeaseRegistry(now = { 1L })
        val old = registry.enable("peer", "first", 1000)
        val fresh = registry.enable("peer", "second", 1000)
        assertFalse(registry.admits("peer", "first", old.id))
        assertTrue(registry.admits("peer", "second", fresh.id))
        registry.enable("peer2", "session", 1000)
        assertThrows(IllegalStateException::class.java) { registry.enable("peer3", "session", 1000) }
        registry.clear()
        assertFalse(registry.admits("peer", "second", fresh.id))
    }

    @Test fun privateNativeAuthenticationNeverLeaksIntoClientGreetingAndPreservesFirstRequest() {
        val nativeOut = java.io.ByteArrayOutputStream()
        GatewaySocksHandshake.authenticateNative(java.io.ByteArrayInputStream(byteArrayOf(5,2,1,0)), nativeOut, "a".repeat(64), "b".repeat(64))
        assertEquals(134, nativeOut.size())
        val clientIn = java.io.ByteArrayInputStream(byteArrayOf(5,1,0,5,1,0,1))
        val clientOut = java.io.ByteArrayOutputStream()
        GatewaySocksHandshake.acceptClient(clientIn, clientOut)
        assertArrayEquals(byteArrayOf(5,0), clientOut.toByteArray())
        assertEquals(5, clientIn.read())
        assertThrows(IllegalArgumentException::class.java) {
            GatewaySocksHandshake.authenticateNative(java.io.ByteArrayInputStream(byteArrayOf(5,0)), java.io.ByteArrayOutputStream(), "a".repeat(64), "b".repeat(64))
        }
        assertThrows(IllegalArgumentException::class.java) {
            GatewaySocksHandshake.acceptClient(java.io.ByteArrayInputStream(byteArrayOf(5,0)), java.io.ByteArrayOutputStream())
        }
    }

    @Test fun healthyControlRenewsBeyondOriginalExpiryButRevokedSessionsNeverResurrect() {
        var clock = 1L
        val registry = InternetLeaseRegistry(now = { clock })
        val lease = registry.enable("peer", "control", 1_000)
        clock = 500
        registry.renew("peer", "control")
        clock = 1_500
        assertTrue(registry.admits("peer", "control", lease.id))
        registry.revoke("peer", "control")
        registry.renew("peer", "control")
        assertFalse(registry.admits("peer", "control", lease.id))
        val fresh = registry.enable("peer", "new-control", 1_000)
        registry.revoke("peer", "old-control")
        assertTrue(registry.admits("peer", "new-control", fresh.id))
    }

    @Test fun repeatedSameLeasePollingPreservesIdentityAndRenewsWithoutRotation() {
        var clock = 1L
        val registry = InternetLeaseRegistry(now = { clock })
        val first = registry.enable("peer", "session", 1_000)
        clock = 900
        val polled = registry.enable("peer", "session", 1_000, first.id)
        assertEquals(first.id, polled.id)
        assertEquals(1_900L, polled.expiresAtMillis)
        clock = 1_500
        assertTrue(registry.admits("peer", "session", first.id))
    }

    @Test fun sameLeasePollKeepsFlowsWhileDifferentLeaseClosesOnlyItsPeer() {
        val flows = mutableSetOf("first-peer-flow", "second-peer-flow")
        val registry = InternetLeaseRegistry(now = { 1L }, onPeerRotation = { peer -> flows.remove("$peer-flow") })
        val first = registry.enable("first-peer", "session", 1_000)
        registry.enable("second-peer", "session", 1_000)
        flows.add("first-peer-flow"); flows.add("second-peer-flow")
        repeat(5) { registry.enable("first-peer", "session", 1_000, first.id) }
        assertTrue("Status polling must keep established flows", "first-peer-flow" in flows)
        val newID = "d5e1590c-47fb-4d73-9ac2-45988ba0a876"
        registry.enable("first-peer", "session", 1_000, newID)
        assertFalse("first-peer-flow" in flows)
        assertTrue("second-peer-flow" in flows)
        assertFalse(registry.admits("first-peer", "session", first.id))
    }

}
