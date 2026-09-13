package com.xopmc.galaxybridge.service

internal class RemoteTextBatcher(
    private val deliver: (String) -> Unit,
) {
    private val pending = StringBuilder()
    private var generation = 0L

    @Synchronized
    fun enqueue(text: String): Long {
        val available = MAX_TEXT_LENGTH - pending.length
        if (available > 0) pending.append(text.take(available))
        generation += 1
        return generation
    }

    fun flush(expectedGeneration: Long): Boolean {
        val text = synchronized(this) {
            if (expectedGeneration != generation || pending.isEmpty()) return false
            drain()
        }
        deliver(text)
        return true
    }

    fun flushNow(): Boolean {
        val text = synchronized(this) {
            if (pending.isEmpty()) return false
            drain()
        }
        deliver(text)
        return true
    }

    private fun drain(): String = pending.toString().also { pending.setLength(0) }

    private companion object {
        const val MAX_TEXT_LENGTH = 4_096
    }
}
