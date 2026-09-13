package com.xopmc.galaxybridge

import org.junit.Assert.assertEquals
import org.junit.Test

class VersionNameTest {
    @Test
    fun publicDistributionsShareTheStableApplicationId() {
        val expected = if (BuildConfig.DISTRIBUTION == "internal") {
            "com.xopmc.galaxybridge.internal"
        } else {
            "com.xopmc.galaxybridge"
        }

        assertEquals(expected, BuildConfig.APPLICATION_ID)
    }

    @Test
    fun distributionFlavorOwnsExactlyOneVersionSuffix() {
        val expected = when (BuildConfig.DISTRIBUTION) {
            "internal" -> "0.1.0-internal"
            "direct" -> "0.1.0-direct"
            "play" -> "0.1.0"
            else -> error("Unknown distribution ${BuildConfig.DISTRIBUTION}")
        }

        assertEquals(expected, BuildConfig.VERSION_NAME)
    }
}
