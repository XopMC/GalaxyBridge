package com.xopmc.galaxybridge.transport

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Process-local signal that pairing state stored by the foreground service has changed. */
object PairingStateBus {
    private val mutableRevision = MutableStateFlow(0L)
    val revision = mutableRevision.asStateFlow()

    internal fun publishSuccess() {
        mutableRevision.update { it + 1 }
    }
}
