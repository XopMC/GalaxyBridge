package com.xopmc.galaxybridge.transport.shell

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class BoundedShellConnectorTest {
    @Test fun retirementWakesBlockedReaderBeforeClosingDescriptor() {
        val released = CountDownLatch(1)
        val readerDone = CountDownLatch(1)
        val order = mutableListOf<String>()
        val reader = Thread { released.await(200, TimeUnit.MILLISECONDS); if (released.count == 0L) readerDone.countDown() }
        reader.start()
        ShellSocketRetirement.close({ order.add("input"); released.countDown() }, { order.add("output") }, { order.add("close") })
        assertEquals(listOf("input", "output", "close"), order)
        assertTrue(readerDone.await(100, TimeUnit.MILLISECONDS))
        reader.join(200)
    }
    @Test fun failedShutdownDoesNotSkipOtherDirectionOrDescriptorClose() {
        val order = mutableListOf<String>()
        ShellSocketRetirement.close({ order.add("input"); throw IOException("not connected") },
            { order.add("output"); throw IOException("already shut down") }, { order.add("close") })
        assertEquals(listOf("input", "output", "close"), order)
    }

    @Test fun successDoesNotCloseSocketLater() {
        val closed = AtomicInteger()
        BoundedShellConnector.connect(30, { false }, { closed.incrementAndGet() }, {})
        Thread.sleep(50)
        assertEquals(0, closed.get())
    }
    @Test fun deadlineClosesSocketAndRejectsLateSuccessfulConnect() {
        val closed = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val before = System.nanoTime()
        val error = assertThrows(IOException::class.java) {
            BoundedShellConnector.connect(30, { false }, { closed.countDown() }) {
                // Simulate a native connect which completes only after another thread closes it.
                try { closed.await(250, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { /* Native connect may complete after cancellation. */ }
                finished.countDown()
            }
        }
        assertEquals("shell_connect_timeout", error.message)
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - before) < 200)
        assertTrue(closed.await(100, TimeUnit.MILLISECONDS))
        assertTrue(finished.await(200, TimeUnit.MILLISECONDS))
    }
    @Test fun cancellationClosesInflightSocketBeforeDeadline() {
        val started = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val cancel = Thread { assertTrue(started.await(200, TimeUnit.MILLISECONDS)); cancelled.set(true) }
        cancel.start()
        val error = assertThrows(IOException::class.java) {
            BoundedShellConnector.connect(1_000, cancelled::get, { closed.countDown() }) {
                started.countDown(); closed.await(250, TimeUnit.MILLISECONDS)
            }
        }
        cancel.join(200)
        assertEquals("shell_connect_cancelled", error.message)
        assertEquals(0L, closed.count)
    }
    @Test fun runtimeUsesBinderFdTransportAndProviderChecksCallerBeforeExtras() {
        fun source(name: String): String {
            val path = "src/main/java/com/xopmc/galaxybridge/transport/shell/$name.kt"
            return listOf(java.io.File(path), java.io.File("app/$path")).first { it.isFile }.readText()
        }
        val runtime = source("ShellBridgeRuntime")
        val endpoint = source("ShellBinderEndpoint")
        val provider = source("ShellBridgeAttachProvider")
        assertFalse(runtime.contains("LocalSocket"))
        assertFalse(runtime.contains(".connect("))
        assertTrue(runtime.contains("ShellBinderEndpoint.open"))
        assertTrue(endpoint.contains("request.writeInterfaceToken(DESCRIPTOR)"))
        assertTrue(endpoint.contains("ParcelFileDescriptor.dup(descriptor.fileDescriptor)"))
        assertTrue(endpoint.contains("ParcelFileDescriptor.createSocketPair()"))
        assertTrue(endpoint.indexOf("ParcelFileDescriptor.createSocketPair()") < endpoint.indexOf("BoundedShellConnector.connect("))
        assertTrue(endpoint.contains("peer.writeToParcel(request, 0)"))
        assertTrue(endpoint.contains("runCatching { peer.close() }"))
        assertFalse(endpoint.contains("retireParcel(peer)"))
        assertFalse(endpoint.contains("CREATOR.createFromParcel(reply)"))
        assertTrue(endpoint.contains("Os.shutdown(descriptor.fileDescriptor, OsConstants.SHUT_RDWR)"))
        assertTrue(provider.indexOf("admitsCaller(caller)") < provider.indexOf("extras?.getBinder"))
        assertTrue(provider.indexOf("enforceCallingPermission") < provider.indexOf("extras?.getBinder"))
    }

    @Test fun factoryFdReturnedAfterTimeoutIsRetiredExactlyOnce() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val callerDone = CountDownLatch(1)
        val retired = CountDownLatch(1)
        val retireCount = AtomicInteger()
        val asset = Any()
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>()
        val caller = Thread {
            try {
                BoundedShellResource.open(300, { false }, { value ->
                    assertSame(asset, value); retireCount.incrementAndGet(); retired.countDown()
                }) {
                    entered.countDown()
                    while (release.count > 0) {
                        try { release.await(200, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {}
                    }
                    asset
                }
                failure.set(AssertionError("late factory result admitted"))
            } catch (error: Throwable) { failure.set(error) }
            finally { callerDone.countDown() }
        }
        caller.start()
        try {
            assertTrue("Factory must actually start before testing late ownership", entered.await(200, TimeUnit.MILLISECONDS))
            assertTrue(callerDone.await(600, TimeUnit.MILLISECONDS))
            assertTrue(failure.get() is IOException)
            assertEquals("shell_connect_timeout", failure.get()?.message)
            assertEquals(0, retireCount.get())
        } finally { release.countDown(); caller.join(500) }
        assertTrue(retired.await(500, TimeUnit.MILLISECONDS))
        assertEquals(1, retireCount.get())
    }
    @Test fun successfulFactoryTransfersOwnershipWithoutRetirement() {
        val asset = Any()
        val retired = AtomicInteger()
        assertSame(asset, BoundedShellResource.open(300, { false }, { _: Any -> retired.incrementAndGet() }) { asset })
        assertEquals(0, retired.get())
    }

    @Test fun preCancelledNeverStartsAndErrorsNeverExposeIoData() {
        val calls = AtomicInteger()
        val error = assertThrows(IOException::class.java) {
            BoundedShellConnector.connect(100, { true }, {}, { calls.incrementAndGet() })
        }
        assertEquals("shell_connect_cancelled", error.message)
        assertEquals(0, calls.get())
        val failure = assertThrows(IOException::class.java) {
            BoundedShellConnector.connect(100, { false }, {}, { throw IOException("private fixture endpoint") })
        }
        assertEquals("shell_connect_failed", failure.message)
        assertTrue(failure.cause is IOException)
        assertEquals("private fixture endpoint", failure.cause?.message)
    }
}
