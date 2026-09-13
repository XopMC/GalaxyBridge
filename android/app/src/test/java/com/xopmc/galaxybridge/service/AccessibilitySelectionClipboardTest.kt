package com.xopmc.galaxybridge.service

import com.xopmc.galaxybridge.protocol.v1.ClipboardKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AccessibilitySelectionClipboardTest {
    @Test
    fun explicitCopyPublishesOnlyTheSelectedNonSensitiveText() {
        val tracker = ClipboardChangeTracker(ClipboardEchoSuppressor())

        val payload = AccessibilitySelectionClipboard.payload(
            text = "before GB_SELECTED_404 after",
            selectionStart = 7,
            selectionEnd = 22,
            isPassword = false,
            generation = 1,
            tracker = tracker,
        )

        assertEquals(ClipboardKind.CLIPBOARD_KIND_TEXT, payload?.kind)
        assertEquals("GB_SELECTED_404", payload?.content?.decodeToString())
        assertNull(
            AccessibilitySelectionClipboard.payload(
                text = "password",
                selectionStart = 0,
                selectionEnd = 8,
                isPassword = true,
                generation = 2,
                tracker = ClipboardChangeTracker(ClipboardEchoSuppressor()),
            ),
        )
        assertNull(
            AccessibilitySelectionClipboard.payload(
                text = "nothing selected",
                selectionStart = 3,
                selectionEnd = 3,
                isPassword = false,
                generation = 3,
                tracker = ClipboardChangeTracker(ClipboardEchoSuppressor()),
            ),
        )
        assertNull(
            AccessibilitySelectionClipboard.payload(
                text = "bad bounds",
                selectionStart = -1,
                selectionEnd = 20,
                isPassword = false,
                generation = 4,
                tracker = ClipboardChangeTracker(ClipboardEchoSuppressor()),
            ),
        )
    }

    @Test
    fun explicitCopyPublishesSelectionWhenChromeRejectsAccessibilityCopyAction() {
        assertEquals(
            true,
            AccessibilitySelectionClipboard.shouldPublish(
                isCopy = true,
                actionHandled = false,
                payloadAvailable = true,
            ),
        )
        assertEquals(
            false,
            AccessibilitySelectionClipboard.shouldPublish(
                isCopy = false,
                actionHandled = false,
                payloadAvailable = true,
            ),
        )
        assertEquals(
            true,
            AccessibilitySelectionClipboard.shouldPublish(
                isCopy = false,
                actionHandled = true,
                payloadAvailable = true,
            ),
        )
        assertEquals(
            false,
            AccessibilitySelectionClipboard.shouldPublish(
                isCopy = true,
                actionHandled = false,
                payloadAvailable = false,
            ),
        )
    }

    @Test
    fun explicitCopyIsNotSuppressedAsAnEchoOfTheTextJustPastedFromMac() {
        val suppressor = ClipboardEchoSuppressor()
        val tracker = ClipboardChangeTracker(suppressor)
        val content = "gb_copy_808".encodeToByteArray()
        suppressor.markInbound(ClipboardKind.CLIPBOARD_KIND_TEXT, content)

        val first = AccessibilitySelectionClipboard.payload(
            text = "gb_copy_808",
            selectionStart = 0,
            selectionEnd = 11,
            isPassword = false,
            generation = 10,
            tracker = tracker,
        )
        val second = AccessibilitySelectionClipboard.payload(
            text = "gb_copy_808",
            selectionStart = 0,
            selectionEnd = 11,
            isPassword = false,
            generation = 11,
            tracker = tracker,
        )

        assertEquals("gb_copy_808", first?.content?.decodeToString())
        assertEquals("gb_copy_808", second?.content?.decodeToString())
        assertEquals(false, first?.changeId == second?.changeId)
    }
}
