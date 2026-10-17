package com.xopmc.galaxybridge.nearby

import org.junit.Assert.*
import org.junit.Test

class NearbyBluetoothEnablePolicyTest {
    @Test fun passiveRefreshAndAnExistingDialogNeverLaunchAnotherPrompt() {
        assertEquals(NearbyBluetoothEnableAction.Wait, NearbyBluetoothEnablePolicy.decide(false, false, false))
        assertEquals(NearbyBluetoothEnableAction.Wait, NearbyBluetoothEnablePolicy.decide(true, false, true))
        assertEquals(NearbyBluetoothEnableAction.RequestEnable, NearbyBluetoothEnablePolicy.decide(true, false, false))
        assertEquals(NearbyBluetoothEnableAction.Continue, NearbyBluetoothEnablePolicy.decide(true, true, false))
        assertEquals(NearbyBluetoothEnableAction.Continue, NearbyBluetoothEnablePolicy.decide(true, null, false))
    }

    @Test fun firstJourneyExcludesPairedUpgradesCompletionOptOutAndMissingPermission() {
        fun eligible(completed: Boolean = false, paired: Boolean = false, enabled: Boolean = true,
            granted: Boolean = true, radio: Boolean? = false) =
            NearbyBluetoothEnablePolicy.atFirstLaunchCompletion(completed, paired, enabled, granted, radio)
        assertTrue(eligible())
        assertFalse(eligible(completed = true))
        assertFalse(eligible(paired = true))
        assertFalse(eligible(enabled = false))
        assertFalse(eligible(granted = false))
        assertFalse(eligible(radio = true))
        assertFalse(eligible(radio = null))
        assertFalse(NearbyBluetoothEnablePolicy.atFirstLaunchCompletion(false, false, true, true, false, previouslyRequested = true))
    }
}
