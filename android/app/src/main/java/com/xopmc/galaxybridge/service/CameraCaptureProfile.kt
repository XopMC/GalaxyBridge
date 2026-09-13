package com.xopmc.galaxybridge.service

import kotlin.math.roundToInt

internal data class CameraCaptureProfile(
    val width: Int,
    val height: Int,
    val fps: Int,
    val frontCamera: Boolean,
    val bitRate: Int,
)

internal object CameraCaptureProfileResolver {
    private const val DEFAULT_WIDTH = 1_920
    private const val DEFAULT_HEIGHT = 1_080
    private const val DEFAULT_FPS = 30
    private const val MAX_DIMENSION = 2_560

    fun resolve(
        requestedWidth: Int,
        requestedHeight: Int,
        requestedFps: Int,
        requestedCameraId: String,
    ): CameraCaptureProfile {
        val initialWidth = requestedWidth.takeIf { it > 0 } ?: DEFAULT_WIDTH
        val initialHeight = requestedHeight.takeIf { it > 0 } ?: DEFAULT_HEIGHT
        val scale = (MAX_DIMENSION.toDouble() / maxOf(initialWidth, initialHeight)).coerceAtMost(1.0)
        val width = ((initialWidth * scale).roundToInt().coerceAtLeast(2)) and -2
        val height = ((initialHeight * scale).roundToInt().coerceAtLeast(2)) and -2
        val fps = requestedFps.takeIf { it > 0 }?.coerceIn(15, 60) ?: DEFAULT_FPS
        return CameraCaptureProfile(
            width = width,
            height = height,
            fps = fps,
            frontCamera = requestedCameraId == "front",
            bitRate = recommendedBitRate(width, height, fps),
        )
    }

    fun recommendedBitRate(width: Int, height: Int, fps: Int): Int = when {
        width.toLong() * height > DEFAULT_WIDTH.toLong() * DEFAULT_HEIGHT || fps > DEFAULT_FPS -> 12_000_000
        width.toLong() * height <= 1_280L * 720 -> 6_000_000
        else -> 8_000_000
    }
}

internal class CameraCaptureSessionGuard {
    class Session internal constructor(
        internal val generation: Long,
        val epoch: Int,
    )

    private var generation = 0L

    @Synchronized
    fun beginSession(epoch: Int): Session {
        generation = nextPositive(generation)
        return Session(generation, epoch)
    }

    @Synchronized
    fun invalidateCurrentSession() {
        generation = nextPositive(generation)
    }

    @Synchronized
    fun isCurrent(session: Session): Boolean = session.generation == generation

    fun runIfCurrent(session: Session, action: () -> Unit) {
        if (isCurrent(session)) action()
    }

    private fun nextPositive(value: Long): Long = if (value == Long.MAX_VALUE) 1 else value + 1
}

internal class CameraEncoderSessionGuard<Codec : Any> {
    class Session<Codec : Any> internal constructor(
        internal val generation: Long,
        internal val codec: Codec,
        val epoch: Int,
    )

    private var generation = 0L
    private var currentCodec: Codec? = null

    @Synchronized
    fun beginSession(codec: Codec, epoch: Int): Session<Codec> {
        generation = nextPositive(generation)
        currentCodec = codec
        return Session(generation, codec, epoch)
    }

    @Synchronized
    fun invalidateCurrentSession() {
        generation = nextPositive(generation)
        currentCodec = null
    }

    @Synchronized
    fun isCurrent(session: Session<Codec>, codec: Codec): Boolean =
        session.generation == generation && session.codec === codec && currentCodec === codec

    fun runIfCurrent(session: Session<Codec>, codec: Codec, action: () -> Unit) {
        if (isCurrent(session, codec)) action()
    }

    fun handleOutput(
        session: Session<Codec>,
        codec: Codec,
        releaseOutput: () -> Unit,
        action: (Int) -> Unit,
    ) {
        try {
            if (isCurrent(session, codec)) action(session.epoch)
        } finally {
            releaseOutput()
        }
    }

    private fun nextPositive(value: Long): Long = if (value == Long.MAX_VALUE) 1 else value + 1
}
