package com.xopmc.galaxybridge.transport.shell

/** Immutable identity of the verified broker JAR, never a phone identifier. */
internal object ShellRuntimeIdentity {
    fun encode(bytes: ByteArray): String {
        require(bytes.isEmpty() || bytes.size == 32)
        return bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
    fun decode(hex: String): ByteArray {
        if (hex.isEmpty()) return ByteArray(0) // Older broker; Mac decides whether to upgrade.
        require(hex.length == 64 && hex.all { it in '0'..'9' || it in 'a'..'f' })
        return ByteArray(32) { index -> hex.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }
}
