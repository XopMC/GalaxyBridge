package com.xopmc.galaxybridge.service

import android.media.MediaCodec

internal class CameraStreamingReadiness {
    private var activeEpoch: Int? = null
    private var announced = false

    @Synchronized
    fun begin(epoch: Int) {
        activeEpoch = epoch
        announced = false
    }

    @Synchronized
    fun stop() {
        activeEpoch = null
        announced = false
    }

    @Synchronized
    fun shouldAnnounce(epoch: Int, flags: Int, size: Int): Boolean {
        if (activeEpoch != epoch || announced || size <= 0) return false
        if (flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) return false
        announced = true
        return true
    }
}
