package com.xopmc.galaxybridge.transport

/** Process-wide budget includes old connections whose mutations are still settling. */
internal class CompanionControlAdmission(private val maxPerHost: Int = 2, private val maxTotal: Int = 32) {
    private val lock = Any()
    private val owners = mutableMapOf<String, MutableSet<Any>>()

    init { require(maxPerHost > 0 && maxTotal > 0) }

    fun acquire(hostID: String): Permit? = synchronized(lock) {
        if (owners[hostID].orEmpty().size >= maxPerHost || owners.values.sumOf { it.size } >= maxTotal)
            return@synchronized null
        val token = Any()
        owners.getOrPut(hostID) { mutableSetOf() }.add(token)
        Permit {
            synchronized(lock) {
                owners[hostID]?.let { tokens ->
                    tokens.remove(token)
                    if (tokens.isEmpty()) owners.remove(hostID)
                }
            }
        }
    }

    class Permit internal constructor(private val release: () -> Unit) : AutoCloseable {
        override fun close() = release()
    }
}
