package com.xopmc.galaxybridge.security

/** One process-wide boundary for the shared Android identity and its stable ID. */
internal object DeviceIdentityCoordinator {
    private val lock = Any()

    fun <T> withIdentity(operation: () -> T): T = synchronized(lock, operation)

    fun getOrCreateDeviceId(
        read: () -> String?,
        generate: () -> String,
        commit: (String) -> Boolean,
    ): String = withIdentity {
        read() ?: generate().also { value ->
            check(commit(value)) { "Unable to persist Galaxy Bridge device identity" }
        }
    }
}
