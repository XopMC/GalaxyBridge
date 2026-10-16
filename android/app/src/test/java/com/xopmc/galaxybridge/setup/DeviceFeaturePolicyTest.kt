package com.xopmc.galaxybridge.setup

import org.junit.Assert.*
import org.junit.Test

class DeviceFeaturePolicyTest {
    @org.junit.Test fun privacyBelongsToEitherPrimaryScreenOrApplicationWindows() {
        org.junit.Assert.assertTrue(DeviceFeaturePolicy.canUsePanel(setOf("screen")))
        org.junit.Assert.assertTrue(DeviceFeaturePolicy.canUsePanel(setOf("applications")))
        org.junit.Assert.assertTrue(DeviceFeaturePolicy.canUsePanel(setOf("screen", "applications")))
        org.junit.Assert.assertFalse(DeviceFeaturePolicy.canUsePanel(emptySet()))
        org.junit.Assert.assertFalse(DeviceFeaturePolicy.canUsePanel(setOf("files")))
    }

    @Test fun defaultsEnableEveryShippingFeatureAndExplicitAllOffSurvives() {
        assertEquals(DeviceFeaturePolicy.shippingIDs, DeviceFeaturePolicy.enabledIDs(null))
        assertTrue(DeviceFeaturePolicy.enabledIDs(emptySet()).isEmpty())
        assertFalse("calls" in DeviceFeaturePolicy.shippingIDs)
        assertFalse("sms" in DeviceFeaturePolicy.shippingIDs)
    }
    @Test fun authenticatedPolicyRejectsCrossPhoneStaleAndMalformedUpdates() {
        val good = DeviceFeatureRequest("host", "session", "phone", "c6ae882b-f502-46f0-a40d-44b8e207e022", 8, setOf("clipboard"))
        fun reject(request: DeviceFeatureRequest, revision: Long = 7) = assertNotNull(
            DeviceFeaturePolicy.rejection(request, "host", "session", "phone", revision))
        assertNull(DeviceFeaturePolicy.rejection(good, "host", "session", "phone", 7))
        reject(good.copy(hostID = "other")); reject(good.copy(sessionID = "old")); reject(good.copy(deviceID = "other"))
        reject(good, 8); reject(good.copy(revision = 0)); reject(good.copy(requestID = "x"))
        assertNull(DeviceFeaturePolicy.rejection(good.copy(enabledIDs = setOf("calls")), "host", "session", "phone", 7))
        reject(good.copy(enabledIDs = setOf("sms"))); reject(good.copy(enabledIDs = setOf("x".repeat(65))))
        assertNull(DeviceFeaturePolicy.rejection(good.copy(enabledIDs = emptySet()), "host", "session", "phone", 7))
    }
}
