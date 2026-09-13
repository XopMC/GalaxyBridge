package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraCaptureProfileResolverTest {
    @Test
    fun missingControlValuesUseThe1080p30BackCameraDefault() {
        val profile = CameraCaptureProfileResolver.resolve(
            requestedWidth = 0,
            requestedHeight = 0,
            requestedFps = 0,
            requestedCameraId = "",
        )

        assertEquals(1_920, profile.width)
        assertEquals(1_080, profile.height)
        assertEquals(30, profile.fps)
        assertFalse(profile.frontCamera)
        assertEquals(8_000_000, profile.bitRate)
    }

    @Test
    fun qhdSelectionIsNotIndependentlyClampedIntoTheWrongAspectRatio() {
        val profile = CameraCaptureProfileResolver.resolve(
            requestedWidth = 2_560,
            requestedHeight = 1_440,
            requestedFps = 60,
            requestedCameraId = "back",
        )

        assertEquals(2_560, profile.width)
        assertEquals(1_440, profile.height)
        assertEquals(60, profile.fps)
        assertEquals(12_000_000, profile.bitRate)
    }

    @Test
    fun oversizedRequestsScaleBothDimensionsTogetherAndRemainEven() {
        val profile = CameraCaptureProfileResolver.resolve(
            requestedWidth = 4_000,
            requestedHeight = 3_000,
            requestedFps = 120,
            requestedCameraId = "front",
        )

        assertEquals(2_560, profile.width)
        assertEquals(1_920, profile.height)
        assertEquals(60, profile.fps)
        assertTrue(profile.frontCamera)
        assertEquals(0, profile.width % 2)
        assertEquals(0, profile.height % 2)
    }
}
