package com.xopmc.galaxybridge.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BonjourAdvertisementTest {
    @Test
    fun publishesOnlyStablePublicIdentityAndPresentationFields() {
        val attributes = BonjourAdvertisement.attributes(
            deviceId = "a7ce395c-2f84-49a7-bb39-91a43a3b08b7",
            publicKeyFingerprint = byteArrayOf(0x00, 0x0f, 0x80.toByte(), 0xff.toByte()),
            displayName = "SM-S928B",
            protocolMajor = 1,
        )

        assertEquals("a7ce395c-2f84-49a7-bb39-91a43a3b08b7", attributes["id"])
        assertEquals("000f80ff", attributes["pkfp"])
        assertEquals("SM-S928B", attributes["name"])
        assertEquals("1", attributes["v"])
        assertEquals(setOf("id", "pkfp", "name", "v"), attributes.keys)
        assertFalse(attributes.keys.any { it.contains("token", ignoreCase = true) })
        assertFalse(attributes.keys.any { it.contains("secret", ignoreCase = true) })
    }

    @Test
    fun serviceInstanceNameIsModelOnlyAndAllowsNsdToSuffixCollisions() {
        assertEquals("GalaxyBridge SM-S928B", BonjourAdvertisement.serviceName("SM-S928B"))
        assertTrue(BonjourAdvertisement.serviceName(" ").startsWith("GalaxyBridge"))
    }
}
