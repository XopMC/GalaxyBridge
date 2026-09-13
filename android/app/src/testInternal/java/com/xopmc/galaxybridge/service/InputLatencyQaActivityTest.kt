package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class InputLatencyQaActivityTest {
    @Test
    fun eachAcceptedTouchAdvancesSequenceAndAlternatesFullScreenMarker() {
        val first = nextInputLatencyQaState(-1)
        val second = nextInputLatencyQaState(first.sequence)
        val third = nextInputLatencyQaState(second.sequence)

        assertEquals(1L, first.sequence)
        assertEquals(2L, second.sequence)
        assertEquals(3L, third.sequence)
        assertEquals(first.backgroundArgb, third.backgroundArgb)
        assertEquals(first.foregroundArgb, third.foregroundArgb)
        assertEquals(0xff123b7a.toInt(), second.backgroundArgb)
        assertEquals(0xffffffff.toInt(), second.foregroundArgb)
    }

    @Test
    fun markerContainsOnlySequenceAndDeviceUptime() {
        assertEquals(
            "down_sequence=7 event_uptime_ms=123456",
            inputLatencyQaMarker(sequence = 7, eventUptimeMillis = 123456),
        )
    }
}
