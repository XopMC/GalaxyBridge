package com.xopmc.galaxybridge.transport

import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OutboundChannelLifecycleTest {
    @Test
    fun aNewLogicalSessionEvictsEverySocketFromThePreviousBundle() {
        val registry = CompanionSessionRegistry()
        val oldControl = TrackingCloseable()
        val oldVideo = TrackingCloseable()
        val newControl = TrackingCloseable()

        registry.register("mac", "old", oldControl)
        registry.register("mac", "old", oldVideo)
        registry.register("mac", "new", newControl)

        assertTrue(oldControl.closed.get())
        assertTrue(oldVideo.closed.get())
        assertTrue(!newControl.closed.get())

        registry.unregister("mac", "old", oldControl)
        assertEquals(1, registry.socketCount("mac", "new"))
    }

    @Test
    fun oneBrokenClientIsContainedAndCannotCancelTheLanServer() = runBlocking {
        val closeCount = AtomicInteger()
        var failureType: String? = null

        AcceptedClientLifecycle.run(
            closeTransport = { closeCount.incrementAndGet() },
            reportFailure = { failureType = it },
        ) {
            error("broken pipe")
        }

        assertEquals("IllegalStateException", failureType)
        assertEquals(1, closeCount.get())
    }

    @Test(expected = CancellationException::class)
    fun serverCancellationStillPropagatesThroughAClientHandler() = runBlocking {
        AcceptedClientLifecycle.run(
            closeTransport = {},
            reportFailure = { error("cancellation must not be reported as a client fault") },
        ) {
            throw CancellationException("server stopped")
        }
    }

    @Test
    fun peerCloseCancelsAnIdleOutboundProducerAndClosesTheTransport() = runBlocking {
        val peerInput = PipedInputStream()
        val peerOutput = PipedOutputStream(peerInput)
        val closeCount = AtomicInteger()
        val producerCancelled = AtomicBoolean()

        val channel = launch {
            OutboundChannelLifecycle.run(
                peerInput = peerInput,
                closeTransport = {
                    closeCount.incrementAndGet()
                    peerInput.close()
                },
            ) {
                try {
                    awaitCancellation()
                } finally {
                    producerCancelled.set(true)
                }
            }
        }

        peerOutput.close()
        withTimeout(1_000) { channel.join() }

        assertTrue(producerCancelled.get())
        assertEquals(1, closeCount.get())
    }

    @Test
    fun producerFailureClosesTheTransportAndUnblocksThePeerWatcher() = runBlocking {
        val peerInput = PipedInputStream()
        val peerOutput = PipedOutputStream(peerInput)
        val closeCount = AtomicInteger()
        var failure: Throwable? = null

        try {
            withTimeout(1_000) {
                OutboundChannelLifecycle.run(
                    peerInput = peerInput,
                    closeTransport = {
                        closeCount.incrementAndGet()
                        peerInput.close()
                    },
                ) {
                    error("write failed")
                }
            }
        } catch (error: Throwable) {
            failure = error
        } finally {
            peerOutput.close()
        }

        assertEquals("write failed", failure?.message)
        assertEquals(1, closeCount.get())
    }

    private class TrackingCloseable : Closeable {
        val closed = AtomicBoolean()
        override fun close() {
            closed.set(true)
        }
    }
}
