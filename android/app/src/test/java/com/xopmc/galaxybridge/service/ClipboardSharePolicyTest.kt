package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipboardSharePolicyTest {
    @Test
    fun acceptsOnlyExplicitSendTextAndWebUrlPayloads() {
        assertNull(ClipboardSharePolicy.text("android.intent.action.VIEW", "text/plain", "hello"))
        assertNull(ClipboardSharePolicy.text(ClipboardSharePolicy.ACTION_SEND, "text/html", "hello"))
        assertNull(ClipboardSharePolicy.text(ClipboardSharePolicy.ACTION_SEND, "text/plain", null))
        assertEquals(
            SharedContentKind.TEXT,
            ClipboardSharePolicy.text(ClipboardSharePolicy.ACTION_SEND, "text/plain", "hello")?.kind,
        )
        assertEquals(
            SharedContentKind.URL,
            ClipboardSharePolicy.text(ClipboardSharePolicy.ACTION_SEND, "text/uri-list", "https://example.com")?.kind,
        )
    }

    @Test
    fun imageRequiresSendActionImageMimeAndContentUri() {
        assertNull(ClipboardSharePolicy.image("android.intent.action.VIEW", "image/png", "content"))
        assertNull(ClipboardSharePolicy.image(ClipboardSharePolicy.ACTION_SEND, "application/octet-stream", "content"))
        assertNull(ClipboardSharePolicy.image(ClipboardSharePolicy.ACTION_SEND, "image/png", "file"))
        assertEquals(
            SharedContentKind.IMAGE,
            ClipboardSharePolicy.image(ClipboardSharePolicy.ACTION_SEND, "image/jpeg", "content")?.kind,
        )
    }
}
