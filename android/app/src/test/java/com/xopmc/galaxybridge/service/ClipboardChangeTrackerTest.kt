package com.xopmc.galaxybridge.service

import com.xopmc.galaxybridge.protocol.v1.ClipboardKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardChangeTrackerTest {
    @Test
    fun stableDigestDeduplicatesRepeatedLocalClipboardNotifications() {
        val tracker = ClipboardChangeTracker(ClipboardEchoSuppressor())

        val first = tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, "hello".encodeToByteArray())
        val duplicate = tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, "hello".encodeToByteArray())
        val changed = tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, "world".encodeToByteArray())

        assertNull(duplicate)
        assertTrue(first?.changeId?.endsWith(ClipboardFingerprint.digest(ClipboardKind.CLIPBOARD_KIND_TEXT, "hello".encodeToByteArray())) == true)
        assertNotEquals(first?.changeId, changed?.changeId)
    }

    @Test
    fun inboundDigestIsConsumedBeforeItCanBounceBack() {
        val suppressor = ClipboardEchoSuppressor()
        val tracker = ClipboardChangeTracker(suppressor)
        val content = "from Mac".encodeToByteArray()

        suppressor.markInbound(ClipboardKind.CLIPBOARD_KIND_TEXT, content)

        assertNull(tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content))
        assertNull(tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content))
    }

    @Test
    fun identicalContentCanBeCopiedLocallyAfterTheDedupeWindow() {
        var now = 100L
        val suppressor = ClipboardEchoSuppressor()
        val tracker = ClipboardChangeTracker(
            echoSuppressor = suppressor,
            duplicateWindowMillis = 1_000,
            clockMillis = { now },
        )
        val content = "same content".encodeToByteArray()
        suppressor.markInbound(ClipboardKind.CLIPBOARD_KIND_TEXT, content)

        assertNull(tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content))
        now += 1_001

        val recopied = tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content)

        assertTrue(recopied != null)
    }

    @Test
    fun intentionalRecopyGetsANewOccurrenceIdentity() {
        var now = 100L
        val tracker = ClipboardChangeTracker(
            echoSuppressor = ClipboardEchoSuppressor(),
            duplicateWindowMillis = 1_000,
            clockMillis = { now },
        )
        val content = "same content".encodeToByteArray()

        val first = tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content)
        now += 1_001
        val recopied = tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content)

        assertTrue(first != null)
        assertTrue(recopied != null)
        assertNotEquals(first?.changeId, recopied?.changeId)
    }

    @Test
    fun clipboardGenerationAllowsAnIntentionalRecopyButNotARefocusSample() {
        val tracker = ClipboardChangeTracker(ClipboardEchoSuppressor())
        val content = "same content".encodeToByteArray()

        assertTrue(tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content, generation = 10) != null)
        assertNull(tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content, generation = 10))
        assertTrue(tracker.prepare(ClipboardKind.CLIPBOARD_KIND_TEXT, content, generation = 11) != null)
    }

    @Test
    fun echoSuppressorIsBounded() {
        val suppressor = ClipboardEchoSuppressor(capacity = 1)
        val first = "first".encodeToByteArray()
        val second = "second".encodeToByteArray()

        suppressor.markInbound(ClipboardKind.CLIPBOARD_KIND_TEXT, first)
        suppressor.markInbound(ClipboardKind.CLIPBOARD_KIND_TEXT, second)

        assertFalse(suppressor.consume(ClipboardKind.CLIPBOARD_KIND_TEXT, first))
        assertTrue(suppressor.consume(ClipboardKind.CLIPBOARD_KIND_TEXT, second))
    }
}
