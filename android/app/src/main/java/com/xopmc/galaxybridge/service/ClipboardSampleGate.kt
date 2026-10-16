package com.xopmc.galaxybridge.service

/** Orders completed clipboard reads by observation, not image decoding time. */
class ClipboardSampleGate {
    private var revision = 0L

    @Synchronized
    fun beginSample(): Long = ++revision

    @Synchronized
    fun invalidate() {
        revision++
    }

    @Synchronized
    fun publishIfCurrent(sample: Long, publish: () -> Unit): Boolean {
        if (sample != revision) return false
        publish()
        return true
    }
}
