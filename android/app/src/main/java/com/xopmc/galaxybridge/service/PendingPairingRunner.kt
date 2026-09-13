package com.xopmc.galaxybridge.service

internal class PendingPairingRunner(
    private val attempt: suspend (String) -> Boolean,
    private val currentPending: () -> String?,
    private val expiresAtMillis: (String, Long) -> Long,
    private val nowMillis: () -> Long,
    private val wait: suspend (Long) -> Unit,
    private val clearPendingIfCurrent: suspend (String) -> Unit,
) {
    suspend fun run(uri: String) {
        var retryIndex = 0
        while (currentPending() == uri) {
            val now = nowMillis()
            val expiry = try {
                expiresAtMillis(uri, now)
            } catch (_: Exception) {
                clearPendingIfCurrent(uri)
                return
            }
            if (expiry <= now) {
                clearPendingIfCurrent(uri)
                return
            }

            val succeeded = try {
                attempt(uri)
            } catch (_: Exception) {
                false
            }
            if (succeeded) return

            val retryDelay = RETRY_DELAYS_MILLIS[minOf(retryIndex, RETRY_DELAYS_MILLIS.lastIndex)]
            if (nowMillis() + retryDelay >= expiry) {
                clearPendingIfCurrent(uri)
                return
            }
            wait(retryDelay)
            retryIndex++
        }
    }

    private companion object {
        val RETRY_DELAYS_MILLIS = longArrayOf(1_000L, 2_000L, 5_000L, 10_000L, 30_000L)
    }
}
