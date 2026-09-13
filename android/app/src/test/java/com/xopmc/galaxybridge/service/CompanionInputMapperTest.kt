package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CompanionInputMapperTest {
    @Test
    fun mapsTrackpadScrollToBoundedSwipeAroundPointer() {
        val swipe = CompanionInputMapper.scrollSwipe(
            centerX = 0.5,
            centerY = 0.5,
            scrollX = 8.0,
            scrollY = -16.0,
            displayEpoch = 7,
        )

        requireNotNull(swipe)
        assertEquals(0.40, swipe.fromX, 0.0001)
        assertEquals(0.70, swipe.fromY, 0.0001)
        assertEquals(0.60, swipe.toX, 0.0001)
        assertEquals(0.30, swipe.toY, 0.0001)
        assertEquals(160, swipe.durationMillis)
        assertEquals(7, swipe.displayEpoch)
    }

    @Test
    fun clampsScrollGestureToDisplayAndRejectsInvalidOrEmptyDelta() {
        val swipe = CompanionInputMapper.scrollSwipe(
            centerX = 0.98,
            centerY = 0.02,
            scrollX = 16.0,
            scrollY = -16.0,
            displayEpoch = 3,
        )

        requireNotNull(swipe)
        assertTrue(swipe.fromX in 0.0..1.0)
        assertTrue(swipe.fromY in 0.0..1.0)
        assertTrue(swipe.toX in 0.0..1.0)
        assertTrue(swipe.toY in 0.0..1.0)
        assertNull(CompanionInputMapper.scrollSwipe(0.5, 0.5, 0.0, 0.0, 0))
        assertNull(CompanionInputMapper.scrollSwipe(0.5, 0.5, Double.NaN, 1.0, 0))
    }

    @Test
    fun pointerMovesPreserveTheOriginalDownPointAndEmitOneFinalSwipe() {
        val gestures = CompanionPointerGestureAccumulator()

        gestures.down(pointerId = 7, x = 0.50, y = 0.82)
        gestures.move(pointerId = 7, x = 0.50, y = 0.70)
        gestures.move(pointerId = 7, x = 0.50, y = 0.48)
        val command = gestures.up(pointerId = 7, x = 0.50, y = 0.24, displayEpoch = 9)

        assertEquals(
            AndroidInputCommand.Swipe(
                fromX = 0.50,
                fromY = 0.82,
                toX = 0.50,
                toY = 0.24,
                durationMillis = 120,
                displayEpoch = 9,
            ),
            command,
        )
    }

    @Test
    fun pointerTapAndCancelDoNotLeaveAStaleGesture() {
        val gestures = CompanionPointerGestureAccumulator()

        gestures.down(pointerId = 3, x = 0.25, y = 0.40)
        assertEquals(
            AndroidInputCommand.Tap(0.252, 0.404, 4),
            gestures.up(pointerId = 3, x = 0.252, y = 0.404, displayEpoch = 4),
        )

        gestures.down(pointerId = 3, x = 0.1, y = 0.1)
        gestures.cancel(pointerId = 3)
        assertEquals(
            AndroidInputCommand.Tap(0.9, 0.9, 5),
            gestures.up(pointerId = 3, x = 0.9, y = 0.9, displayEpoch = 5),
        )
    }

    @Test
    fun mapsNavigationEditingAndMacCommandShortcuts() {
        assertEquals(AccessibilityKeyOperation.Global(GlobalAction.BACK), CompanionInputMapper.keyOperation(4, 0))
        assertEquals(AccessibilityKeyOperation.Enter, CompanionInputMapper.keyOperation(66, 0))
        assertEquals(AccessibilityKeyOperation.DeleteBackward, CompanionInputMapper.keyOperation(67, 0))
        assertEquals(AccessibilityKeyOperation.MoveLeft, CompanionInputMapper.keyOperation(21, 0))
        assertEquals(AccessibilityKeyOperation.PageDown, CompanionInputMapper.keyOperation(93, 0))
        assertEquals(AccessibilityKeyOperation.SelectAll, CompanionInputMapper.keyOperation(29, META_CTRL_ON))
        assertEquals(AccessibilityKeyOperation.Copy, CompanionInputMapper.keyOperation(31, META_CTRL_ON))
        assertEquals(AccessibilityKeyOperation.Paste, CompanionInputMapper.keyOperation(50, META_CTRL_ON))
        assertEquals(AccessibilityKeyOperation.Cut, CompanionInputMapper.keyOperation(52, META_CTRL_ON))
        assertNull(CompanionInputMapper.keyOperation(29, 0))
        assertNull(CompanionInputMapper.keyOperation(54, META_CTRL_ON))
    }

    @Test
    fun insertsTextAtSelectionWithoutReplacingTheWholeField() {
        assertEquals(
            TextEditResult("Galaxy Bridge", 8),
            CompanionInputMapper.replaceSelection("Galaxy ridge", 7, 7, "B"),
        )
        assertEquals(
            TextEditResult("hello!", 6),
            CompanionInputMapper.replaceSelection("hello", -1, -1, "!"),
        )
        assertEquals(
            TextEditResult("hio", 2),
            CompanionInputMapper.replaceSelection("hello", 1, 4, "i"),
        )
    }

    @Test
    fun deletesWholeUnicodeCodePointsAroundTheCaret() {
        assertEquals(
            TextEditResult("AB", 1),
            CompanionInputMapper.deleteSelection("A😀B", 3, 3, backward = true),
        )
        assertEquals(
            TextEditResult("AB", 1),
            CompanionInputMapper.deleteSelection("A😀B", 1, 1, backward = false),
        )
        assertEquals(
            TextEditResult("AD", 1),
            CompanionInputMapper.deleteSelection("ABCD", 1, 3, backward = true),
        )
    }
}
