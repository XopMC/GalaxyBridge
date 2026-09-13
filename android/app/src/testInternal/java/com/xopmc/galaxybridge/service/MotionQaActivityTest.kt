package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class MotionQaActivityTest {
    @Test
    fun stateIsStableBeforeFirstFrameAndAdvancesDeterministically() {
        assertEquals(
            MotionFrameState(frameNumber = 0, elapsedMillis = 0, offsetPixels = 0),
            motionFrameState(
                frameTimeNanos = 500_000_000,
                startTimeNanos = 1_000_000_000,
                cellSizePixels = 64,
            ),
        )

        assertEquals(
            MotionFrameState(frameNumber = 59, elapsedMillis = 1_000, offsetPixels = 52),
            motionFrameState(
                frameTimeNanos = 2_000_000_000,
                startTimeNanos = 1_000_000_000,
                cellSizePixels = 64,
            ),
        )
    }
}
