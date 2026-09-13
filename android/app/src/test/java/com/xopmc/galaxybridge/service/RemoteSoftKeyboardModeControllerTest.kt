package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteSoftKeyboardModeControllerTest {
    @Test
    fun `active remote capture hides the phone keyboard and stopping restores it`() {
        val applied = mutableListOf<Boolean>()
        val controller = RemoteSoftKeyboardModeController(applied::add)

        controller.setCaptureActive(true)
        controller.setCaptureActive(true)
        controller.setCaptureActive(false)
        controller.setCaptureActive(false)

        assertEquals(listOf(true, false), applied)
    }

    @Test
    fun `accessibility reconnect reapplies the current capture mode`() {
        val applied = mutableListOf<Boolean>()
        val controller = RemoteSoftKeyboardModeController(applied::add)

        controller.setCaptureActive(true)
        applied.clear()
        controller.reapply()

        assertEquals(listOf(true), applied)
    }
}
