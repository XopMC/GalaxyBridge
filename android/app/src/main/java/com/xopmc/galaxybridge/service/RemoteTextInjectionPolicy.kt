package com.xopmc.galaxybridge.service

internal object RemoteTextInjectionPolicy {
    fun deliver(
        accessibility: () -> Boolean,
        imeFallback: () -> Boolean,
    ): Boolean = accessibility() || imeFallback()
}
