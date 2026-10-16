package com.xopmc.galaxybridge.internet

/** Native server has no public socket, config paths, shell commands, or process-wide network binding. */
object NativeInternetGateway {
    @Volatile private var loaded = false
    @Synchronized fun load(): Boolean {
        if (loaded) return true
        return runCatching { System.loadLibrary("galaxybridge_internet"); loaded = true; true }.getOrDefault(false)
    }
    @JvmStatic external fun start(configYaml: String, networkHandle: Long): Long
    @JvmStatic external fun stop(handle: Long): Int
    @JvmStatic external fun updateNetwork(handle: Long, networkHandle: Long): Int
    @JvmStatic external fun localPort(handle: Long): Int
}
