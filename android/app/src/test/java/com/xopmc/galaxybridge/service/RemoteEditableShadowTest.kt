package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteEditableShadowTest {
    @Test
    fun `stale accessibility snapshots do not overwrite earlier remote text`() {
        val shadow = RemoteEditableShadow(expiryMillis = 1_000)

        val first = shadow.resolve(
            editorKey = "window:search",
            observedText = "",
            observedSelectionStart = 0,
            observedSelectionEnd = 0,
            nowMillis = 100,
        )
        shadow.applied("window:search", TextEditResult("GB_LAN", 6), nowMillis = 100)

        val second = shadow.resolve(
            editorKey = "window:search",
            observedText = "",
            observedSelectionStart = 0,
            observedSelectionEnd = 0,
            nowMillis = 180,
        )

        assertEquals(EditorSnapshot("", 0, 0), first)
        assertEquals(EditorSnapshot("GB_LAN", 6, 6), second)
    }

    @Test
    fun `matching accessibility snapshot becomes the new authoritative selection`() {
        val shadow = RemoteEditableShadow(expiryMillis = 1_000)
        shadow.applied("window:search", TextEditResult("Galaxy", 6), nowMillis = 100)

        val resolved = shadow.resolve(
            editorKey = "window:search",
            observedText = "Galaxy",
            observedSelectionStart = 2,
            observedSelectionEnd = 4,
            nowMillis = 140,
        )

        assertEquals(EditorSnapshot("Galaxy", 2, 4), resolved)
    }

    @Test
    fun `explicit remote selection survives an invalid accessibility selection snapshot`() {
        val shadow = RemoteEditableShadow(expiryMillis = 1_000)
        shadow.applied("window:search", TextEditResult("GB_ACCESS_COPY_606", 18), nowMillis = 100)
        shadow.selected(
            editorKey = "window:search",
            observedText = "GB_ACCESS_COPY_606",
            selectionStart = 0,
            selectionEnd = 18,
            nowMillis = 120,
        )

        val resolved = shadow.resolve(
            editorKey = "window:search",
            observedText = "GB_ACCESS_COPY_606",
            observedSelectionStart = -1,
            observedSelectionEnd = -1,
            nowMillis = 140,
        )

        assertEquals(EditorSnapshot("GB_ACCESS_COPY_606", 0, 18), resolved)
    }

    @Test
    fun `an out of order intermediate snapshot cannot replace optimistic content`() {
        val shadow = RemoteEditableShadow(expiryMillis = 1_000)
        shadow.applied("window:search", TextEditResult("GB_LAN", 6), nowMillis = 100)

        assertEquals(
            EditorSnapshot("GB_LAN", 6, 6),
            shadow.resolve("window:search", "_L", 2, 2, nowMillis = 180),
        )
    }

    @Test
    fun `new editor and expired shadow use observed content`() {
        val shadow = RemoteEditableShadow(expiryMillis = 1_000)
        shadow.applied("window:first", TextEditResult("stale", 5), nowMillis = 100)

        assertEquals(
            EditorSnapshot("second", 6, 6),
            shadow.resolve("window:second", "second", 6, 6, nowMillis = 150),
        )

        shadow.applied("window:second", TextEditResult("remote", 6), nowMillis = 200)
        assertEquals(
            EditorSnapshot("local", 5, 5),
            shadow.resolve("window:second", "local", 5, 5, nowMillis = 1_201),
        )
    }

    @Test
    fun `explicit invalidation drops optimistic content`() {
        val shadow = RemoteEditableShadow(expiryMillis = 1_000)
        shadow.applied("window:search", TextEditResult("remote", 6), nowMillis = 100)
        shadow.invalidate()

        assertEquals(
            EditorSnapshot("local", 5, 5),
            shadow.resolve("window:search", "local", 5, 5, nowMillis = 110),
        )
    }
}
