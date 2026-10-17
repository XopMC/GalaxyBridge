package com.xopmc.galaxybridge.nearby

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NearbyDiscoveryRecoveryTest {
    @Test fun onlyKnownPeerFailuresLeaveDiscoveryAvailable() {
        for (error in listOf("ble_session_rejected", "ble_bootstrap_rejected", "ble_indication_failed")) {
            assertFalse(NearbyDiscoveryRecovery.affectsDiscovery(error))
        }
        for (error in listOf("ble_service_failed", "ble_advertise_failed_2", "ble_permission_or_start_failed", "unknown")) {
            assertTrue(NearbyDiscoveryRecovery.affectsDiscovery(error))
        }
    }

    @Test fun successfulDiscoveryRetiresOnlyBootstrapAndRestartsWhenRadioReturns() {
        assertEquals(NearbyDiscoveryAction.StartBootstrap, decision(radioOn = true, running = false))
        assertEquals(NearbyDiscoveryAction.Keep, decision(radioOn = true, running = true))
        assertEquals(NearbyDiscoveryAction.RetireBootstrap, decision(radioOn = false, running = true))
        // The service's radio receiver can restart discovery without an Activity resume.
        assertEquals(NearbyDiscoveryAction.StartBootstrap, decision(radioOn = true, running = false))
        assertEquals(NearbyDiscoveryAction.Keep, decision(radioOn = true, running = true))
    }

    @Test fun unavailableRadioNeverStartsBootstrapEvenBeforeTheFirstAdvertisement() {
        assertEquals(NearbyDiscoveryAction.RetireBootstrap, decision(radioOn = false, running = false))
    }

    @Test fun explicitDisableStillRetiresWifiGroupsWhenBluetoothIsAlreadyOff() {
        assertEquals(NearbyDiscoveryAction.Disable, NearbyDiscoveryRecovery.decide(
            enabled = false, permissionsGranted = true, radioOn = false, running = false))
    }

    @Test fun permissionRevocationStillRetiresWifiGroupsWhenBluetoothIsAlreadyOff() {
        assertEquals(NearbyDiscoveryAction.Disable, NearbyDiscoveryRecovery.decide(
            enabled = true, permissionsGranted = false, radioOn = false, running = false))
    }

    @Test fun healthyDiscoveryDoesNotRestartOnRoutineRefresh() {
        repeat(3) { assertEquals(NearbyDiscoveryAction.Keep, decision(radioOn = true, running = true)) }
    }

    @Test fun failedBootstrapCanRetryWhileRadioRemainsOn() {
        assertEquals(NearbyDiscoveryAction.StartBootstrap, decision(radioOn = true, running = false))
    }

    private fun decision(radioOn: Boolean, running: Boolean) = NearbyDiscoveryRecovery.decide(
        enabled = true, permissionsGranted = true, radioOn = radioOn, running = running)
}
