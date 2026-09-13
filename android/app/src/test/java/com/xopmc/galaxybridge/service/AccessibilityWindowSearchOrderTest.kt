package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class AccessibilityWindowSearchOrderTest {
    @Test
    fun `focused virtual display editor is searched before the physical active root without duplicates`() {
        assertEquals(
            listOf(189, 10, 7),
            AccessibilityWindowSearchOrder.windowIds(
                activeWindowId = 10,
                preferredWindowId = 189,
                windows = listOf(
                    AccessibilityWindowCandidate(windowId = 7, focused = false),
                    AccessibilityWindowCandidate(windowId = 10, focused = false),
                    AccessibilityWindowCandidate(windowId = 189, focused = false),
                ),
            ),
        )
    }

    @Test
    fun `focused window leads when the active root is absent`() {
        assertEquals(
            listOf(189, 7),
            AccessibilityWindowSearchOrder.windowIds(
                activeWindowId = null,
                preferredWindowId = null,
                windows = listOf(
                    AccessibilityWindowCandidate(windowId = 7, focused = false),
                    AccessibilityWindowCandidate(windowId = 189, focused = true),
                ),
            ),
        )
    }

    @Test
    fun `a stale preferred window is ignored after its virtual display closes`() {
        assertEquals(
            listOf(10, 7),
            AccessibilityWindowSearchOrder.windowIds(
                activeWindowId = 10,
                preferredWindowId = 189,
                windows = listOf(
                    AccessibilityWindowCandidate(windowId = 7, focused = false),
                    AccessibilityWindowCandidate(windowId = 10, focused = false),
                ),
            ),
        )
    }
}
