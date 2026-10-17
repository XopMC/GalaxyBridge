package com.xopmc.galaxybridge.nearby

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class NearbyAdvertisingLifecycle {
    @Volatile var isRunningRequested = false
        private set

    fun begin(available: Boolean): Boolean {
        isRunningRequested = available
        return available
    }

    fun stop() { isRunningRequested = false }
}

internal enum class NearbyDiscoveryStatus { Disabled, BluetoothOff, Starting, Available, Unavailable }

internal object NearbyDiscoveryStatusBus {
    private val mutableStatus = MutableStateFlow(NearbyDiscoveryStatus.Disabled)
    val status = mutableStatus.asStateFlow()
    fun publish(status: NearbyDiscoveryStatus) { mutableStatus.value = status }
}
