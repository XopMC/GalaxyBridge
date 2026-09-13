package com.xopmc.galaxybridge.service

internal data class CaptureDisplaySpec(
    val width: Int,
    val height: Int,
    val densityDpi: Int,
) {
    init {
        require(width > 0)
        require(height > 0)
        require(densityDpi > 0)
    }
}

/**
 * Owns display-change deduplication independently from Android callbacks.
 * A request is valid only for the projection generation and revision that
 * created it, so callbacks already queued by DisplayManager cannot revive a
 * retired projection or an intermediate Fold/rotation geometry.
 */
internal class DisplayCaptureRestartCoordinator(
    private val debounceMillis: Long,
) {
    init {
        require(debounceMillis >= 0)
    }

    class Transition internal constructor(
        val captureGeneration: Long,
        val epoch: Int,
        val spec: CaptureDisplaySpec,
    )

    class RestartRequest internal constructor(
        internal val captureGeneration: Long,
        internal val revision: Long,
        val spec: CaptureDisplaySpec,
        val dueAtMillis: Long,
    )

    sealed interface Observation {
        data object Ignored : Observation
        data object CancelPending : Observation
        data class Schedule(val request: RestartRequest) : Observation
    }

    private var captureGeneration = 0L
    private var revision = 0L
    private var epoch = 0
    private var activeSpec: CaptureDisplaySpec? = null
    private var pendingRequest: RestartRequest? = null

    fun beginCapture(spec: CaptureDisplaySpec): Transition {
        captureGeneration = nextPositive(captureGeneration)
        revision = nextPositive(revision)
        pendingRequest = null
        activeSpec = spec
        epoch = nextPositive(epoch)
        return Transition(captureGeneration, epoch, spec)
    }

    fun invalidateCapture() {
        captureGeneration = nextPositive(captureGeneration)
        revision = nextPositive(revision)
        activeSpec = null
        pendingRequest = null
    }

    fun observe(
        expectedCaptureGeneration: Long,
        spec: CaptureDisplaySpec,
        nowMillis: Long,
    ): Observation {
        if (expectedCaptureGeneration != captureGeneration || activeSpec == null) {
            return Observation.Ignored
        }
        if (spec == activeSpec) {
            if (pendingRequest == null) return Observation.Ignored
            revision = nextPositive(revision)
            pendingRequest = null
            return Observation.CancelPending
        }
        if (pendingRequest?.spec == spec) return Observation.Ignored

        revision = nextPositive(revision)
        val request = RestartRequest(
            captureGeneration = captureGeneration,
            revision = revision,
            spec = spec,
            dueAtMillis = saturatingAdd(nowMillis, debounceMillis),
        )
        pendingRequest = request
        return Observation.Schedule(request)
    }

    fun commit(request: RestartRequest): Transition? {
        if (
            pendingRequest !== request ||
            request.captureGeneration != captureGeneration ||
            request.revision != revision ||
            request.spec == activeSpec
        ) {
            return null
        }
        pendingRequest = null
        activeSpec = request.spec
        epoch = nextPositive(epoch)
        return Transition(captureGeneration, epoch, request.spec)
    }

    private fun nextPositive(value: Long): Long = if (value == Long.MAX_VALUE) 1 else value + 1

    private fun nextPositive(value: Int): Int = if (value == Int.MAX_VALUE) 1 else value + 1

    private fun saturatingAdd(left: Long, right: Long): Long =
        if (left > Long.MAX_VALUE - right) Long.MAX_VALUE else left + right
}
