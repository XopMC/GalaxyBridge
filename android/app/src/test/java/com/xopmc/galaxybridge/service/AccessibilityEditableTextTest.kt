package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class AccessibilityEditableTextTest {
    @Test
    fun `an accessibility hint is not treated as editable content`() {
        assertEquals(
            "",
            AccessibilityEditableText.current(
                text = "Спросите Google",
                isShowingHintText = true,
            ),
        )
    }

    @Test
    fun `real editable content is preserved`() {
        assertEquals(
            "GB_LAN_КЛАВА_42",
            AccessibilityEditableText.current(
                text = "GB_LAN_КЛАВА_42",
                isShowingHintText = false,
            ),
        )
    }
}
