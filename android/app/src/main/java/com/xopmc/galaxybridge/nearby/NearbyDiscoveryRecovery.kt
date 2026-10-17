package com.xopmc.galaxybridge.nearby

internal enum class NearbyDiscoveryAction { Keep, StartBootstrap, RetireBootstrap, Disable }

/** Radio availability retires discovery only; permission/opt-in loss also retires groups. */
internal object NearbyDiscoveryRecovery {
    // A rejected peer is retired independently; the advertiser remains usable
    // by other peers. Unknown failures still fail discovery visibly.
    fun affectsDiscovery(error: String): Boolean = error !in setOf(
        "ble_session_rejected", "ble_bootstrap_rejected", "ble_indication_failed",
    )

    fun decide(enabled: Boolean, permissionsGranted: Boolean, radioOn: Boolean, running: Boolean): NearbyDiscoveryAction = when {
        !enabled || !permissionsGranted -> NearbyDiscoveryAction.Disable
        !radioOn -> NearbyDiscoveryAction.RetireBootstrap
        !running -> NearbyDiscoveryAction.StartBootstrap
        else -> NearbyDiscoveryAction.Keep
    }
}
