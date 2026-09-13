package com.xopmc.galaxybridge.service

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioVideoQaSignalTest {
    @Test
    fun generatedToneHasBoundedDurationAmplitudeFrequencyAndSilentEdges() {
        val pcm = audioVideoQaTone()
        assertTrue(QA_AUDIO_DURATION_SECONDS in 15..30)
        assertEquals(QA_AUDIO_SAMPLE_RATE * QA_AUDIO_DURATION_SECONDS, pcm.size)
        assertEquals(0, pcm.first().toInt())
        assertEquals(0, pcm.last().toInt())
        assertTrue(pcm.maxOf { abs(it.toInt()) } in 320..328)
        val positiveCrossings = (QA_AUDIO_SAMPLE_RATE + 1 until QA_AUDIO_SAMPLE_RATE * 2)
            .count { pcm[it - 1] <= 0 && pcm[it] > 0 }
        assertEquals(440, positiveCrossings)
    }
}
