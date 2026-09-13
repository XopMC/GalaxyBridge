package com.xopmc.galaxybridge.service

import org.junit.Assert.*
import org.junit.Test

class VideoBootstrapBufferTest {
    private data class Frame(val epoch: Int, val kind: String, val bytes: Int = 1, val pts: Long = 0)
    private fun buffer() = VideoBootstrapBuffer<Frame>(
        maxBytes = 8, maxFrames = 4,
        epoch = { it.epoch }, isConfiguration = { it.kind == "config" },
        isKeyFrame = { it.kind == "key" }, size = { it.bytes },
    )

    @Test fun `idle screen snapshot contains the entire decodable current image`() {
        val buffer = buffer()
        val config = Frame(1, "config")
        val key = Frame(1, "key")
        val p1 = Frame(1, "p1")
        val p2 = Frame(1, "p2")
        listOf(config, key, p1, p2).forEach { buffer.offer(it) }
        // No subsequent surface frame arrives. A viewer must still receive
        // the latest image, not only the stale IDR or codec configuration.
        assertEquals(listOf(config, key, p1, p2), buffer.snapshot())
        val newer = Frame(1, "key", 2)
        buffer.offer(newer)
        assertEquals(listOf(config, newer), buffer.snapshot())
    }

    @Test fun `overflow never exposes an undecodable GOP suffix`() {
        val buffer = buffer()
        buffer.offer(Frame(1, "config"))
        buffer.offer(Frame(1, "key", 7))
        assertFalse(buffer.offer(Frame(1, "p", 2)))
        assertTrue(buffer.snapshot().isEmpty())
        assertFalse(buffer.offer(Frame(1, "p")))
        assertTrue(buffer.offer(Frame(1, "key")))
        assertEquals(2, buffer.snapshot().size)
    }

    @Test fun `epoch changes and capture stop do not replay old images`() {
        val buffer = buffer()
        buffer.offer(Frame(1, "config"))
        buffer.offer(Frame(1, "key"))
        buffer.offer(Frame(2, "config"))
        assertTrue(buffer.snapshot().isEmpty())
        assertFalse(buffer.offer(Frame(1, "key")))
        buffer.offer(Frame(2, "key"))
        assertEquals(listOf(Frame(2, "config"), Frame(2, "key")), buffer.snapshot())
        buffer.clear()
        assertTrue(buffer.snapshot().isEmpty())
    }

    @Test fun `reconnecting viewer presents cached GOP now instead of dropping it against live audio`() {
        val buffer = buffer()
        val config = Frame(1, "config")
        val key = Frame(1, "key", pts = 1_000)
        val delta = Frame(1, "p", pts = 2_000)
        listOf(config, key, delta).forEach { buffer.offer(it) }
        val reconnectTime = 5_000_000L
        val snapshot = buffer.snapshotForPresentation(reconnectTime) { frame, now -> frame.copy(pts = now) }
        assertEquals(listOf(config, key.copy(pts = reconnectTime), delta.copy(pts = reconnectTime)), snapshot)
        assertEquals(listOf(config, key, delta), buffer.snapshot())
    }
}
