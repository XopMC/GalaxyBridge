package com.xopmc.galaxybridge.service

/** Main-looper confined. Admission is not proof that Android executed a command. */
internal class RemoteInputCompletionQueue(
    private val execute: (AndroidInputCommand, Long) -> Execution,
    private val scheduleTimeout: (Long, Long) -> Unit,
    private val cancelTimeout: (Long) -> Unit,
    private val maxCommands: Int = 128,
    private val maxTextBytes: Int = 65_536,
) {
    sealed interface Execution {
        data object Completed : Execution
        data object Rejected : Execution
        data class Gesture(val timeoutMillis: Long) : Execution
    }
    private val pending = ArrayDeque<AndroidInputCommand>()
    private var inFlight: Long? = null
    private var nextTicket = 0L
    private var blocked = false
    private var closed = false
    private var draining = false
    private var textBytes = 0
    val isIdle: Boolean get() = !closed && !blocked && inFlight == null && pending.isEmpty()

    fun enqueue(command: AndroidInputCommand): Boolean {
        if (closed || blocked) return false
        val bytes = (command as? AndroidInputCommand.Text)?.text?.toByteArray()?.size ?: 0
        if (pending.size >= maxCommands || bytes > maxTextBytes - textBytes) {
            // The next key may depend on the rejected text/tap. Discard that
            // pending sequence rather than silently executing a partial one.
            abortPending()
            return false
        }
        val previous = pending.lastOrNull()
        if (command is AndroidInputCommand.Scroll && previous is AndroidInputCommand.Scroll &&
            command.displayEpoch == previous.displayEpoch
        ) {
            pending.removeLast()
            pending.addLast(command.copy(
                scrollX = (previous.scrollX + command.scrollX).coerceIn(-16.0, 16.0),
                scrollY = (previous.scrollY + command.scrollY).coerceIn(-16.0, 16.0),
            ))
        } else {
            pending.addLast(command)
        }
        textBytes += bytes
        drain()
        return true
    }

    fun completed(ticket: Long, successful: Boolean) {
        if (closed || inFlight != ticket) return
        cancelTimeout(ticket)
        inFlight = null
        if (!successful) clearPending()
        blocked = false
        if (!closed) drain()
    }

    fun timeout(ticket: Long) {
        if (inFlight != ticket) return
        clearPending()
        // Keep the physical gesture lease: elapsed time does not prove it
        // stopped, and another dispatchGesture could cancel an active gesture.
        blocked = true
    }

    fun abortPending() {
        clearPending()
        blocked = inFlight != null
    }

    fun close() {
        closed = true
        clearPending()
        inFlight?.let(cancelTimeout)
        blocked = true
    }

    private fun drain() {
        if (draining) return
        draining = true
        try {
            while (!closed && !blocked && inFlight == null && pending.isNotEmpty()) {
                val command = pending.removeFirst()
                textBytes -= (command as? AndroidInputCommand.Text)?.text?.toByteArray()?.size ?: 0
                val ticket = ++nextTicket
                inFlight = ticket
                val result = execute(command, ticket)
                // Permit an immediate callback without resurrecting its lease.
                if (inFlight != ticket) continue
                when (result) {
                    Execution.Completed -> inFlight = null
                    Execution.Rejected -> {
                        inFlight = null
                        clearPending()
                    }
                    is Execution.Gesture -> scheduleTimeout(ticket, result.timeoutMillis)
                }
            }
        } finally {
            draining = false
        }
    }

    private fun clearPending() {
        pending.clear()
        textBytes = 0
    }
}
