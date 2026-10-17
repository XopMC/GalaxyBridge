package com.xopmc.galaxybridge.core

/** Foreground-owner lifecycle, serialized by the caller. Never grants notification access.
 * The scheduler must enqueue callbacks, including zero-delay callbacks, rather than invoke inline. */
class NotificationListenerRecovery(
    private val state: () -> State,
    private val requestBind: () -> Unit,
    private val schedule: (Long, () -> Unit) -> (() -> Unit),
) {
    data class State(val enabled: Boolean, val accessGranted: Boolean, val connected: Boolean)
    private var owner = false
    private var generation = 0L
    private var recovering = false
    private var attempt = 0
    private var cancelPending: (() -> Unit)? = null
    private val delays = longArrayOf(0, 2_000, 8_000, 20_000)

    fun ownerStarted() { owner = true; retry() }
    fun ownerStopped() { owner = false; cancel() }
    fun listenerConnected() = cancel()
    fun featureChanged() { cancel(); retry() }
    fun retry() {
        if (!owner || recovering) return
        recovering = true; attempt = 0
        enqueue(0, ++generation)
    }
    private fun cancel() {
        generation++; recovering = false
        cancelPending?.invoke(); cancelPending = null
    }
    private fun enqueue(delay: Long, expected: Long) {
        try { cancelPending = schedule(delay) { perform(expected) } }
        catch (_: Exception) { cancel() }
    }
    private fun perform(expected: Long) {
        if (!owner || expected != generation) return
        cancelPending = null
        val current = try { state() } catch (_: Exception) { cancel(); return }
        if (!current.enabled || !current.accessGranted || current.connected) { cancel(); return }
        try { requestBind() } catch (_: Exception) { /* A rejected request gets only the remaining bounded retries. */ }
        if (!owner || expected != generation) return
        attempt++
        if (attempt < delays.size) enqueue(delays[attempt], expected)
        else recovering = false
    }
}
