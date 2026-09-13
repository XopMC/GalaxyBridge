package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioPresentationTimebaseTest {
    @Test
    fun audioSamplesUseTheSameMonotonicDomainAsSurfaceVideo() {
        val videoPresentationTimeUs = 9_876_553_210L
        val timebase = AudioPresentationTimebase(
            originTimeUs = 9_876_543_210L,
            sampleRate = 48_000,
        )

        assertEquals(9_876_543_210L, timebase.presentationTimeUs(frameOffset = 0))
        assertEquals(
            videoPresentationTimeUs,
            timebase.presentationTimeUs(frameOffset = 480),
        )
    }

    @Test
    fun twoHoursOf48KhzSamplesRemainExact() {
        val timebase = AudioPresentationTimebase(
            originTimeUs = 50_000_000_000L,
            sampleRate = 48_000,
        )

        assertEquals(
            57_200_000_000L,
            timebase.presentationTimeUs(frameOffset = 345_600_000L),
        )
    }

    @Test
    fun replacementCaptureUsesItsOwnFreshOrigin() {
        val retired = AudioPresentationTimebase(originTimeUs = 1_000_000L, sampleRate = 48_000)
        val replacement = AudioPresentationTimebase(originTimeUs = 8_000_000L, sampleRate = 48_000)

        assertEquals(1_000_000L, retired.presentationTimeUs(frameOffset = 0))
        assertEquals(8_000_000L, replacement.presentationTimeUs(frameOffset = 0))
    }

    @Test
    fun extremeFrameOffsetsSaturateInsteadOfWrapping() {
        val timebase = AudioPresentationTimebase(
            originTimeUs = Long.MAX_VALUE - 5,
            sampleRate = 48_000,
        )

        assertEquals(Long.MAX_VALUE, timebase.presentationTimeUs(frameOffset = 480))
        assertEquals(Long.MAX_VALUE, timebase.presentationTimeUs(frameOffset = Long.MAX_VALUE))
    }
}
