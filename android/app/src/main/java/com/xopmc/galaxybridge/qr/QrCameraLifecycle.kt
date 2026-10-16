package com.xopmc.galaxybridge.qr

internal class QrCameraLifecycle {
    private var active = true

    @Synchronized fun runIfActive(action: () -> Unit): Boolean {
        if (!active) return false
        action()
        return true
    }

    @Synchronized fun dispose() { active = false }
}
