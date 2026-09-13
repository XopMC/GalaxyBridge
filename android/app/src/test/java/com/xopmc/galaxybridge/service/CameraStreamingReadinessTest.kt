package com.xopmc.galaxybridge.service

import android.media.MediaCodec
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraStreamingReadinessTest {
    @Test
    fun `streaming is announced only after first real encoded frame`() {
        val readiness = CameraStreamingReadiness()
        readiness.begin(epoch = 4)

        assertFalse(readiness.shouldAnnounce(epoch = 4, flags = MediaCodec.BUFFER_FLAG_CODEC_CONFIG, size = 32))
        assertFalse(readiness.shouldAnnounce(epoch = 4, flags = 0, size = 0))
        assertTrue(readiness.shouldAnnounce(epoch = 4, flags = MediaCodec.BUFFER_FLAG_KEY_FRAME, size = 1024))
        assertFalse(readiness.shouldAnnounce(epoch = 4, flags = 0, size = 512))
    }

    @Test
    fun `stale callbacks cannot announce a replacement session`() {
        val readiness = CameraStreamingReadiness()
        readiness.begin(epoch = 9)

        assertFalse(readiness.shouldAnnounce(epoch = 8, flags = MediaCodec.BUFFER_FLAG_KEY_FRAME, size = 128))
        assertTrue(readiness.shouldAnnounce(epoch = 9, flags = MediaCodec.BUFFER_FLAG_KEY_FRAME, size = 128))
        readiness.stop()
        assertFalse(readiness.shouldAnnounce(epoch = 9, flags = 0, size = 128))
    }
}
