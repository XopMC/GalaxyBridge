package com.xopmc.galaxybridge.service

import com.xopmc.galaxybridge.protocol.v1.ClipboardKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipboardPayloadPolicyTest {
    @Test
    fun excludesSensitiveAndOversizedTextAndClassifiesWebLinks() {
        val tracker = ClipboardChangeTracker(ClipboardEchoSuppressor())

        assertNull(ClipboardPayloadPolicy.text("secret", sensitive = true, tracker = tracker))
        assertNull(
            ClipboardPayloadPolicy.text(
                "x".repeat(ClipboardPayloadPolicy.MAX_TEXT_CHARACTERS + 1),
                sensitive = false,
                tracker = tracker,
            ),
        )
        assertEquals(
            ClipboardKind.CLIPBOARD_KIND_URL,
            ClipboardPayloadPolicy.text("https://example.com/path", sensitive = false, tracker = tracker)?.kind,
        )
        assertEquals(
            ClipboardKind.CLIPBOARD_KIND_TEXT,
            ClipboardPayloadPolicy.text("example.com", sensitive = false, tracker = tracker)?.kind,
        )
    }

    @Test
    fun imagePayloadMustAlreadyBeBounded() {
        val tracker = ClipboardChangeTracker(ClipboardEchoSuppressor())

        assertNull(
            ClipboardPayloadPolicy.png(
                ByteArray(ClipboardPayloadPolicy.MAX_IMAGE_BYTES + 1),
                sensitive = false,
                tracker = tracker,
            ),
        )
    }
}
