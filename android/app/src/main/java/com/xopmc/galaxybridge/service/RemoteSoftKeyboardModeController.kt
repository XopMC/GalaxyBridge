package com.xopmc.galaxybridge.service

internal class RemoteSoftKeyboardModeController(
    private val applyHidden: (Boolean) -> Unit,
) {
    private var captureActive = false

    @Synchronized
    fun setCaptureActive(active: Boolean) {
        if (captureActive == active) return
        captureActive = active
        applyHidden(active)
    }

    @Synchronized
    fun reapply() {
        applyHidden(captureActive)
    }
}
