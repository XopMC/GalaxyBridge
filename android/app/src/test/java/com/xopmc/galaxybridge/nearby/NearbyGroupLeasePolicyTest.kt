package com.xopmc.galaxybridge.nearby

import org.junit.Assert.*
import org.junit.Test

class NearbyGroupLeasePolicyTest {
    @Test fun droppedBootstrapRetiresItsUnconfirmedGroupByTheOriginalDeadline() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        policy.bootstrapClosed("ble-a")
        assertNull(policy.expiredLease(45_999))
        assertEquals("lease-a", policy.expiredLease(46_000))
    }

    @Test fun healthyBootstrapAndPollingCannotKeepAnUnconfirmedGroupForever() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertTrue(policy.permits("mac", "lease-a", "ble-a", 45_999))
        assertFalse(policy.permits("mac", "lease-a", "ble-a", 46_000))
        assertEquals("lease-a", policy.expiredLease(46_000))
        assertFalse(policy.confirm("mac", "lease-a", "ble-a", 46_000))
    }

    @Test fun anotherConnectionCannotBlindlyAdoptOrConfirmAPendingGroup() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertFalse(policy.create("mac", "ble-b", "lease-b", 2_000))
        assertFalse(policy.permits("mac", "lease-a", "ble-b", 2_000))
        assertFalse(policy.confirm("mac", "lease-a", "ble-b", 2_000))
        assertEquals("lease-a", policy.leaseID)
        assertEquals("mac", policy.peerID)
    }

    @Test fun confirmationRequiresExactPeerAndLease() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertFalse(policy.confirm("another-mac", "lease-a", "ble-a", 2_000))
        assertFalse(policy.confirm("mac", "another-lease", "ble-a", 2_000))
        assertFalse(policy.confirm("mac", "", "ble-a", 2_000))
        assertEquals("lease-a", policy.expiredLease(46_000))
    }

    @Test fun explicitConfirmationTransfersLifetimeBeyondBluetoothWithinABoundedLease() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertTrue(policy.confirm("mac", "lease-a", "ble-a", 2_000))
        policy.bootstrapClosed("ble-a")
        assertNull(policy.expiredLease(46_999))
        assertTrue(policy.permits("mac", "lease-a", null, 46_999))
        assertFalse(policy.create("mac", "ble-b", "lease-b", 46_999))
        assertEquals("lease-a", policy.expiredLease(47_000))
    }

    @Test fun authenticatedTlsMayCompleteTheExactHandoffAfterBluetoothLoss() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        policy.bootstrapClosed("ble-a")
        assertFalse(policy.confirm("mac", "lease-a", "ble-a", 2_000))
        assertFalse(policy.confirm("another-mac", "lease-a", null, 2_000))
        assertTrue(policy.confirm("mac", "lease-a", null, 2_000))
        assertNull(policy.expiredLease(46_000))
    }

    @Test fun staleBluetoothAndDeadlineCallbacksCannotRetireASuccessorLease() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertTrue(policy.clear("lease-a"))
        assertTrue(policy.create("mac", "ble-b", "lease-b", 10_000))
        policy.bootstrapClosed("ble-a")
        assertFalse(policy.clear("lease-a"))
        assertTrue(policy.confirm("mac", "lease-b", "ble-b", 11_000))
        assertNull(policy.expiredLease(46_000))
        assertEquals("lease-b", policy.leaseID)
    }

    @Test fun sharedPhonesHaveIndependentPendingAndEstablishedLifetimes() {
        val owner = NearbyGroupLeasePolicy()
        val joining = NearbyGroupLeasePolicy()
        assertTrue(owner.create("mac", "owner-ble", "owner-lease", 1_000))
        assertTrue(joining.create("mac", "joining-ble", "joining-lease", 2_000))
        assertTrue(owner.confirm("mac", "owner-lease", "owner-ble", 3_000))
        owner.bootstrapClosed("owner-ble")
        joining.bootstrapClosed("joining-ble")
        assertNull(owner.expiredLease(47_000))
        assertEquals("joining-lease", joining.expiredLease(47_000))
        assertEquals("owner-lease", owner.expiredLease(48_000))
    }

    @Test fun tlsCannotCreateAnUnboundPendingGroupAndClockReversalCannotExtendIt() {
        val policy = NearbyGroupLeasePolicy()
        assertFalse(policy.create("mac", null, "lease-a", 1_000))
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertEquals("lease-a", policy.expiredLease(999))
    }

    @Test fun onlyExactConfirmationRenewsEstablishedLifetimeAndPollsDoNot() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertTrue(policy.confirm("mac", "lease-a", "ble-a", 2_000))
        policy.bootstrapClosed("ble-a")
        assertFalse(policy.confirm("another-mac", "lease-a", null, 40_000))
        assertFalse(policy.confirm("mac", "other-lease", null, 40_000))
        assertTrue(policy.confirm("mac", "lease-a", null, 40_000))
        assertTrue(policy.permits("mac", "lease-a", null, 84_999))
        assertEquals("lease-a", policy.expiredLease(85_000))
        assertFalse(policy.confirm("mac", "lease-a", null, 85_000))
    }

    @Test fun lostConfirmationAcknowledgementCannotCreateAnUnboundedGroup() {
        val policy = NearbyGroupLeasePolicy()
        assertTrue(policy.create("mac", "ble-a", "lease-a", 1_000))
        assertTrue(policy.confirm("mac", "lease-a", "ble-a", 2_000))
        // The phone committed its handoff, but the Mac never receives the ACK
        // and sends no renewals. The same deadline still retires this group.
        policy.bootstrapClosed("ble-a")
        assertEquals("lease-a", policy.expiredLease(47_000))
    }
}
