package com.xopmc.galaxybridge.transport

import java.io.InputStream
import java.io.Closeable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select

/**
 * Runs a server-to-Mac channel until either the outbound producer finishes or
 * the Mac closes its half of the TLS connection.  Waiting only on a Flow
 * producer leaks an idle SSLSocket in CLOSE_WAIT when there is no new media or
 * event to write after the peer disconnects.
 */
internal object OutboundChannelLifecycle {
    suspend fun run(
        peerInput: InputStream,
        closeTransport: () -> Unit,
        produce: suspend () -> Unit,
    ) = coroutineScope {
        val producer = async(start = CoroutineStart.UNDISPATCHED) { produce() }
        val peerWatcher = async(Dispatchers.IO) { peerInput.read() }
        try {
            select<Unit> {
                producer.onAwait { }
                peerWatcher.onAwait { }
            }
        } finally {
            runCatching(closeTransport)
            producer.cancelAndJoin()
            peerWatcher.cancelAndJoin()
        }
    }
}

internal object AcceptedClientLifecycle {
    suspend fun run(
        closeTransport: () -> Unit,
        reportFailure: (String) -> Unit,
        handle: suspend () -> Unit,
    ) {
        try {
            handle()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            reportFailure(error.javaClass.simpleName)
        } finally {
            runCatching(closeTransport)
        }
    }
}

internal class CompanionSessionRegistry {
    private data class Session(
        val sessionId: String,
        val sockets: MutableSet<Closeable>,
    )

    private val lock = Any()
    private val sessionsByHost = mutableMapOf<String, Session>()

    fun register(hostId: String, sessionId: String, socket: Closeable) {
        val stale = synchronized(lock) {
            val current = sessionsByHost[hostId]
            if (current == null || current.sessionId != sessionId) {
                sessionsByHost[hostId] = Session(sessionId, mutableSetOf(socket))
                current?.sockets?.toList().orEmpty()
            } else {
                current.sockets += socket
                emptyList()
            }
        }
        stale.forEach { runCatching(it::close) }
    }

    fun unregister(hostId: String, sessionId: String, socket: Closeable) {
        synchronized(lock) {
            val current = sessionsByHost[hostId] ?: return
            if (current.sessionId != sessionId) return
            current.sockets -= socket
            if (current.sockets.isEmpty()) sessionsByHost.remove(hostId)
        }
    }

    fun closeAll() {
        val sockets = synchronized(lock) {
            val values = sessionsByHost.values.flatMap { it.sockets }
            sessionsByHost.clear()
            values
        }
        sockets.forEach { runCatching(it::close) }
    }

    internal fun socketCount(hostId: String, sessionId: String): Int = synchronized(lock) {
        sessionsByHost[hostId]?.takeIf { it.sessionId == sessionId }?.sockets?.size ?: 0
    }
}
