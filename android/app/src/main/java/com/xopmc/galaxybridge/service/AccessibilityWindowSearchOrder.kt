package com.xopmc.galaxybridge.service

internal data class AccessibilityWindowCandidate(
    val windowId: Int,
    val focused: Boolean,
)

internal object AccessibilityWindowSearchOrder {
    fun windowIds(
        activeWindowId: Int?,
        preferredWindowId: Int?,
        windows: List<AccessibilityWindowCandidate>,
    ): List<Int> = buildList {
        val availableWindowIDs = buildSet {
            if (activeWindowId != null) add(activeWindowId)
            windows.forEach { add(it.windowId) }
        }
        if (preferredWindowId != null && preferredWindowId in availableWindowIDs) {
            add(preferredWindowId)
        }
        windows
            .filter(AccessibilityWindowCandidate::focused)
            .forEach { candidate ->
                if (candidate.windowId !in this) add(candidate.windowId)
            }
        if (activeWindowId != null && activeWindowId !in this) add(activeWindowId)
        windows
            .filterNot(AccessibilityWindowCandidate::focused)
            .forEach { candidate ->
                if (candidate.windowId !in this) add(candidate.windowId)
            }
    }
}
