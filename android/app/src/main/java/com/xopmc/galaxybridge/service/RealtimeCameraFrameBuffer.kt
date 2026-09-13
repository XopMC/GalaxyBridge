package com.xopmc.galaxybridge.service

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/** A bounded real-time queue: under pressure, freshness wins over stale latency. */
internal class RealtimeMediaFrameBuffer<T>(capacity: Int) {
    private val mutableFrames = MutableSharedFlow<T>(
        replay = 0,
        extraBufferCapacity = capacity.also { require(it > 0) },
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    val frames: SharedFlow<T> = mutableFrames.asSharedFlow()

    fun offer(frame: T): Boolean = mutableFrames.tryEmit(frame)
}

internal typealias RealtimeCameraFrameBuffer = RealtimeMediaFrameBuffer<EncodedCameraFrame>
