package com.xopmc.galaxybridge.nearby

internal enum class NearbyBluetoothEnableAction { Continue, Wait, RequestEnable }

/** Only an Activity's explicit request or unfinished first-run journey may prompt. */
internal object NearbyBluetoothEnablePolicy {
    fun decide(explicitRequest: Boolean, radioEnabled: Boolean?, inFlight: Boolean): NearbyBluetoothEnableAction = when {
        inFlight -> NearbyBluetoothEnableAction.Wait
        radioEnabled != false -> NearbyBluetoothEnableAction.Continue
        explicitRequest -> NearbyBluetoothEnableAction.RequestEnable
        else -> NearbyBluetoothEnableAction.Wait
    }

    fun atFirstLaunchCompletion(setupCompleted: Boolean, paired: Boolean, nearbyEnabled: Boolean,
        permissionsGranted: Boolean, radioEnabled: Boolean?, previouslyRequested: Boolean = false): Boolean =
        !setupCompleted && !paired && !previouslyRequested && nearbyEnabled && permissionsGranted && radioEnabled == false
}
