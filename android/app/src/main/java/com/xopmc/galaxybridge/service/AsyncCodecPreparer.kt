package com.xopmc.galaxybridge.service

internal data class PreparedAsyncCodec<C, S, T>(
    val codec: C,
    val surface: S,
    val callbackThread: T,
)

internal class AsyncCodecPreparationCleanupException(cause: Throwable) :
    IllegalStateException("Async codec preparation cleanup failed", cause)

internal class AsyncCodecPreparer<C, S, T>(
    private val createCodec: () -> C,
    private val startCallbackThread: () -> T,
    private val configureCodec: (C) -> Unit,
    private val createInputSurface: (C) -> S,
    private val startCodec: (C) -> Unit,
    private val stopCodec: (C) -> Unit,
    private val releaseCodec: (C) -> Unit,
    private val releaseSurface: (S) -> Unit,
    private val quitCallbackThread: (T) -> Unit,
    private val onPreparationFailure: () -> Unit,
) {
    fun prepare(registerCallback: (C, T) -> Unit): PreparedAsyncCodec<C, S, T>? {
        val codec = runCatching(createCodec).getOrNull() ?: return null
        var callbackThread: T? = null
        var surface: S? = null
        var startAttempted = false
        return try {
            callbackThread = startCallbackThread()
            registerCallback(codec, callbackThread)
            configureCodec(codec)
            surface = createInputSurface(codec)
            startAttempted = true
            startCodec(codec)
            PreparedAsyncCodec(codec, surface, callbackThread)
        } catch (_: Throwable) {
            val cleanupFailures = mutableListOf<Throwable>()
            fun attemptCleanup(action: () -> Unit) {
                runCatching(action).exceptionOrNull()?.let(cleanupFailures::add)
            }
            attemptCleanup(onPreparationFailure)
            surface?.let { attemptCleanup { releaseSurface(it) } }
            if (startAttempted) attemptCleanup { stopCodec(codec) }
            attemptCleanup { releaseCodec(codec) }
            callbackThread?.let { attemptCleanup { quitCallbackThread(it) } }
            if (cleanupFailures.isNotEmpty()) {
                throw AsyncCodecPreparationCleanupException(cleanupFailures.first()).also { failure ->
                    cleanupFailures.drop(1).forEach(failure::addSuppressed)
                }
            }
            null
        }
    }
}
