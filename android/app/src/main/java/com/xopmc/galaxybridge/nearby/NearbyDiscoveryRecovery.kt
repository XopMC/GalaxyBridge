package com.xopmc.galaxybridge.nearby

internal enum class NearbyDiscoveryAction { Keep, StartBootstrap, RetireBootstrap, Disable }

/** Radio availability retires discovery only; permission/opt-in loss also retires groups. */
internal object NearbyDiscoveryRecovery {
    fun decide(enabled: Boolean, permissionsGranted: Boolean, radioOn: Boolean, running: Boolean): NearbyDiscoveryAction = when {
        !enabled || !permissionsGranted -> NearbyDiscoveryAction.Disable
        !radioOn -> NearbyDiscoveryAction.RetireBootstrap
        !running -> NearbyDiscoveryAction.StartBootstrap
        else -> NearbyDiscoveryAction.Keep
    }
}
