package com.xopmc.galaxybridge.transport

import java.util.ArrayDeque

/**
 * Bounded single-consumer queue. Closing admission discards pending work but
 * never interrupts the running mutation: its caller must settle it before
 * retiring resource ownership. Priority is used only by the frame writer.
 */
internal class CompanionControlQueue<T>(
    private val name: String,
    private val maxItems: Int = 32,
    private val maxBytes: Int = 8 * 1024 * 1024,
    private val maxPriorityItems: Int = 8,
    private val maxPriorityBytes: Int = 2048,
    private val authorized: () -> Boolean = { true },
    private val dispatch: (T) -> Unit,
    private val failed: (Exception) -> Unit,
) {
    private data class Entry<T>(val value: T, val bytes: Int, val priority: Boolean)
    private val lock = Object()
    private val ordinary = ArrayDeque<Entry<T>>()
    private val urgent = ArrayDeque<Entry<T>>()
    private var ordinaryCount = 0
    private var urgentCount = 0
    private var retainedBytes = 0
    private var retainedPriorityBytes = 0
    private var accepting = true
    private var worker: Thread? = null

    init { require(maxItems > 0 && maxPriorityItems > 0 && maxBytes > 0 && maxPriorityBytes > 0) }

    fun offer(value: T, bytes: Int, priority: Boolean = false): Boolean = synchronized(lock) {
        require(bytes >= 0)
        if (!accepting || bytes > (if (priority) maxPriorityBytes - retainedPriorityBytes else maxBytes - retainedBytes) ||
            (if (priority) urgentCount >= maxPriorityItems else ordinaryCount >= maxItems)) return@synchronized false
        val entry = Entry(value, bytes, priority)
        if (priority) { urgent.addLast(entry); urgentCount++ } else { ordinary.addLast(entry); ordinaryCount++ }
        if (priority) retainedPriorityBytes += bytes else retainedBytes += bytes
        if (worker == null) {
            worker = Thread(::drain, "GB-control-$name").apply { isDaemon = true; start() }
        }
        lock.notifyAll()
        true
    }

    fun closeAdmission() = synchronized(lock) {
        accepting = false
        for (entry in ordinary) release(entry)
        for (entry in urgent) release(entry)
        ordinary.clear(); urgent.clear()
        lock.notifyAll()
    }

    /** Socket close must unblock the writer before this is called. */
    fun awaitSettled() {
        val thread = synchronized(lock) { worker }
        check(thread !== Thread.currentThread()) { "control_worker_cannot_join_itself" }
        var interrupted = false
        while (thread?.isAlive == true) {
            try { thread.join() } catch (_: InterruptedException) { interrupted = true }
        }
        if (interrupted) Thread.currentThread().interrupt()
    }

    private fun drain() {
        try {
            while (true) {
                val entry = synchronized(lock) {
                    while (accepting && urgent.isEmpty() && ordinary.isEmpty()) lock.wait()
                    if (!accepting) return
                    if (urgent.isNotEmpty()) urgent.removeFirst() else ordinary.removeFirst()
                }
                try {
                    check(authorized()) { "control_authority_changed" }
                    dispatch(entry.value)
                } finally { synchronized(lock) { release(entry) } }
            }
        } catch (error: Exception) {
            closeAdmission()
            runCatching { failed(error) }
        }
    }

    private fun release(entry: Entry<T>) {
        if (entry.priority) retainedPriorityBytes -= entry.bytes else retainedBytes -= entry.bytes
        if (entry.priority) urgentCount-- else ordinaryCount--
    }
}
