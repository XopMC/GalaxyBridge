package com.xopmc.galaxybridge.transport

import android.media.MediaCodec
import com.xopmc.galaxybridge.service.EncodedCameraFrame
import com.xopmc.galaxybridge.service.EncodedVideoFrame
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraStreamConfigurationGateTest {
    @Test
    fun `dropped screen reference requests sync and resumes with configuration plus keyframe`() {
        var requests = 0
        val gate = MediaStreamConfigurationGate<EncodedVideoFrame>(
            epoch = { it.epoch },
            isConfiguration = { it.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 },
            isKeyFrame = { it.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 },
            sequence = { it.sequence },
            requestKeyFrame = { requests++ },
        )
        val config = EncodedVideoFrame(MediaCodec.BUFFER_FLAG_CODEC_CONFIG, 1, 0, byteArrayOf(1), 1)
        val key = EncodedVideoFrame(MediaCodec.BUFFER_FLAG_KEY_FRAME, 1, 100, byteArrayOf(2), 2)
        val p3 = EncodedVideoFrame(0, 1, 200, byteArrayOf(3), 3)
        gate.framesToWrite(config, config)
        assertEquals(listOf(key), gate.framesToWrite(key, config))
        assertEquals(listOf(p3), gate.framesToWrite(p3, config))
        // SharedFlow dropped sequence 4 while the socket was blocked.
        assertEquals(emptyList<EncodedVideoFrame>(), gate.framesToWrite(p3.copy(sequence = 5), config))
        assertEquals(emptyList<EncodedVideoFrame>(), gate.framesToWrite(p3.copy(sequence = 6), config))
        assertEquals(2, requests)
        val recovery = key.copy(sequence = 7)
        assertEquals(listOf(config, recovery), gate.framesToWrite(recovery, config))
        val next = p3.copy(sequence = 8)
        assertEquals(listOf(next), gate.framesToWrite(next, config))
        assertEquals(emptyList<EncodedVideoFrame>(), gate.framesToWrite(recovery, config))
        val tail = p3.copy(sequence = 9)
        assertEquals(listOf(tail), gate.framesToWrite(tail, config))
    }

    @Test
    fun `joining mid GOP withholds dependent frames until a key frame`() {
        val gate = CameraStreamConfigurationGate()
        val config = configuration(1, 1)
        gate.framesToWrite(config, config)
        val dependent = frame(1, 2).copy(flags = 0)
        assertEquals(emptyList<EncodedCameraFrame>(), gate.framesToWrite(dependent, config))
        val key = frame(1, 3)
        assertEquals(listOf(key), gate.framesToWrite(key, config))
        val next = frame(1, 4).copy(flags = 0)
        assertEquals(listOf(next), gate.framesToWrite(next, config))
    }

    @Test
    fun `new epoch injects the latest configuration before its first frame`() {
        val gate = CameraStreamConfigurationGate()
        val epochOneConfig = configuration(epoch = 1, marker = 11)
        val epochTwoConfig = configuration(epoch = 2, marker = 22)

        assertEquals(listOf(epochOneConfig), gate.framesToWrite(epochOneConfig, epochOneConfig))
        val epochOneFrame = frame(epoch = 1, marker = 12)
        assertEquals(listOf(epochOneFrame), gate.framesToWrite(epochOneFrame, epochOneConfig))

        // The configuration event itself may be dropped by a saturated SharedFlow.
        // The first frame of the new epoch must still be preceded by the durable latest config.
        val firstEpochTwoFrame = frame(epoch = 2, marker = 23)
        assertEquals(
            listOf(epochTwoConfig, firstEpochTwoFrame),
            gate.framesToWrite(firstEpochTwoFrame, epochTwoConfig),
        )
    }

    @Test
    fun `frame is withheld until matching configuration exists`() {
        val gate = CameraStreamConfigurationGate()

        assertEquals(emptyList<EncodedCameraFrame>(), gate.framesToWrite(frame(7, 1), latestConfiguration = null))
        assertEquals(
            emptyList<EncodedCameraFrame>(),
            gate.framesToWrite(frame(7, 2), latestConfiguration = configuration(6, 9)),
        )
    }

    @Test
    fun `old queued frames keep flowing while a newer configuration is published`() {
        val gate = CameraStreamConfigurationGate()
        val epochOneConfig = configuration(1, 1)
        val epochTwoConfig = configuration(2, 2)

        gate.framesToWrite(epochOneConfig, epochOneConfig)
        val oldQueuedFrame = frame(1, 3)
        assertEquals(listOf(oldQueuedFrame), gate.framesToWrite(oldQueuedFrame, epochTwoConfig))
    }

    private fun configuration(epoch: Int, marker: Int) = EncodedCameraFrame(
        flags = MediaCodec.BUFFER_FLAG_CODEC_CONFIG,
        epoch = epoch,
        presentationTimeUs = 0,
        payload = byteArrayOf(marker.toByte()),
    )

    private fun frame(epoch: Int, marker: Int) = EncodedCameraFrame(
        flags = MediaCodec.BUFFER_FLAG_KEY_FRAME,
        epoch = epoch,
        presentationTimeUs = marker.toLong(),
        payload = byteArrayOf(marker.toByte()),
    )
}
