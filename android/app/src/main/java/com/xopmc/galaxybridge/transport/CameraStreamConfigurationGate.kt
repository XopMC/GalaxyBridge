package com.xopmc.galaxybridge.transport

import android.media.MediaCodec
import com.xopmc.galaxybridge.service.EncodedCameraFrame

/** Ensures every media epoch starts with codec configuration on each LAN subscriber. */
internal class MediaStreamConfigurationGate<T>(
    private val epoch: (T) -> Int,
    private val isConfiguration: (T) -> Boolean,
    private val isKeyFrame: ((T) -> Boolean)? = null,
    private val sequence: (T) -> Long? = { null },
    private val requestKeyFrame: () -> Unit = {},
) {
    private var configuredEpoch: Int? = null
    private var lastSequence: Long? = null
    private var waitingForKeyFrame = isKeyFrame != null

    fun framesToWrite(
        frame: T,
        latestConfiguration: T?,
    ): List<T> {
        val nextSequence = sequence(frame)
        // Snapshot delivery happens after subscribing. Frames queued while
        // taking/writing that snapshot may already be included in it.
        if (nextSequence != null && lastSequence != null && nextSequence <= lastSequence!!) {
            return emptyList()
        }
        if (nextSequence != null && lastSequence != null && nextSequence != lastSequence!! + 1) {
            configuredEpoch = null
            waitingForKeyFrame = isKeyFrame != null
        }
        lastSequence = nextSequence
        if (isConfiguration(frame)) {
            configuredEpoch = epoch(frame)
            waitingForKeyFrame = isKeyFrame != null
            return listOf(frame)
        }
        if (isKeyFrame != null && (waitingForKeyFrame || configuredEpoch != epoch(frame))) {
            if (!isKeyFrame.invoke(frame)) {
                requestKeyFrame()
                return emptyList()
            }
        }
        waitingForKeyFrame = false
        if (configuredEpoch == epoch(frame)) return listOf(frame)

        val configuration = latestConfiguration?.takeIf {
            epoch(it) == epoch(frame) && isConfiguration(it)
        } ?: return emptyList()
        configuredEpoch = epoch(frame)
        return listOf(configuration, frame)
    }
}

/** Camera-specialized spelling kept at the call site and in focused tests. */
internal class CameraStreamConfigurationGate {
    private val gate = MediaStreamConfigurationGate<EncodedCameraFrame>(
        epoch = EncodedCameraFrame::epoch,
        isConfiguration = { it.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 },
        isKeyFrame = { it.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 },
    )

    fun framesToWrite(
        frame: EncodedCameraFrame,
        latestConfiguration: EncodedCameraFrame?,
    ): List<EncodedCameraFrame> = gate.framesToWrite(frame, latestConfiguration)
}
