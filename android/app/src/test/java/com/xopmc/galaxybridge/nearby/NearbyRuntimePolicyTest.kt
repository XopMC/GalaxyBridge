package com.xopmc.galaxybridge.nearby

import org.junit.Assert.*
import org.junit.Test

class NearbyRuntimePolicyTest {
    @Test fun unverifiedConcurrencyNeverDisconnectsAnExistingWifiStation() {
        assertEquals("sta_p2p_concurrency_unverified", NearbyRadioPolicy.rejection(true, NearbyLinkKind.P2P_OWNER, false, false))
        assertEquals("sta_p2p_concurrency_unverified", NearbyRadioPolicy.rejection(true, NearbyLinkKind.P2P_JOIN, false, true))
        assertEquals("sta_hotspot_concurrency_unsupported", NearbyRadioPolicy.rejection(true, NearbyLinkKind.LOCAL_HOTSPOT, true, false))
        assertEquals("sta_local_wifi_concurrency_unsupported", NearbyRadioPolicy.rejection(true, NearbyLinkKind.LOCAL_WIFI_JOIN, false, true))
        assertNull(NearbyRadioPolicy.rejection(true, NearbyLinkKind.LOCAL_WIFI_JOIN, true, false))
        assertNull(NearbyRadioPolicy.rejection(false, NearbyLinkKind.P2P_OWNER, false, false))
        assertNull(NearbyRadioPolicy.rejection(true, NearbyLinkKind.P2P_OWNER, true, false))
    }

    @Test fun framesSurviveAttFragmentationAndNeverForwardPartialCiphertext() {
        val decoder = NearbyFrameDecoder()
        val wire = NearbyFrameDecoder.encode(byteArrayOf(1, 2, 3, 4)) + NearbyFrameDecoder.encode(byteArrayOf(5))
        assertTrue(decoder.feed(wire.copyOfRange(0, 2)).isEmpty())
        assertTrue(decoder.feed(wire.copyOfRange(2, 5)).isEmpty())
        val frames = decoder.feed(wire.copyOfRange(5, wire.size))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), frames[0])
        assertArrayEquals(byteArrayOf(5), frames[1])
    }

    @Test fun oversizedAndEmptyBleFramesAreRejectedBeforeAllocation() {
        for (header in listOf(byteArrayOf(0,0,0,0), byteArrayOf(127,127,127,127))) {
            assertThrows(IllegalArgumentException::class.java) { NearbyFrameDecoder().feed(header) }
        }
    }

    @Test fun groupRemovalRequiresExactObservedOwnedIdentity() {
        val own = NearbyGroupIdentity("DIRECT-ab-Synthetic", "p2p0", 4, true)
        assertTrue(own.matches(own.copy()))
        assertFalse(own.matches(own.copy(networkName = "DIRECT-cd-Other")))
        assertFalse(own.matches(own.copy(networkId = 5)))
        assertFalse(own.matches(own.copy(groupOwner = false)))
    }
    @Test fun groupOwnershipNeverAdoptsForeignRoleOrChangesAfterClaim() {
        val own = NearbyGroupIdentity("DIRECT-ab-Synthetic", "p2p0", 4, true)
        val state = NearbyGroupOwnership(own.networkName, true)
        assertFalse(state.mayRemove(own))
        assertFalse(state.observe(own.copy(networkName = "DIRECT-xy-Foreign")))
        assertFalse(state.observe(own.copy(groupOwner = false)))
        assertTrue(state.observe(own))
        assertTrue(state.mayRemove(own))
        assertFalse(state.observe(own.copy(interfaceName = "p2p1")))
        assertFalse(state.mayRemove(own.copy(networkId = 99)))
        assertTrue(state.mayRemove(own))
        val join = NearbyGroupOwnership(own.networkName, false)
        assertFalse(join.observe(own))
        assertTrue(join.observe(own.copy(groupOwner = false)))
    }

}
