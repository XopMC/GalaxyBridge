package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageDecodeBudgetTest {
    @Test
    fun rejectsInvalidOrExtremeDimensionsBeforeBitmapAllocation() {
        assertFalse(ImageDecodeBudget.isPlausible(0, 100))
        assertFalse(ImageDecodeBudget.isPlausible(50_000, 50_000))
        assertTrue(ImageDecodeBudget.isPlausible(1440, 3120))
    }

    @Test
    fun sampleSizeBoundsDecodedPixelCount() {
        assertEquals(1, ImageDecodeBudget.sampleSize(1080, 1920))
        assertEquals(4, ImageDecodeBudget.sampleSize(8000, 6000))
    }
}
