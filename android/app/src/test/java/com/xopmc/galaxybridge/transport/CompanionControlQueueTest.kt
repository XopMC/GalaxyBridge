package com.xopmc.galaxybridge.transport

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class CompanionControlQueueTest {
    @Test fun aBlockedCommandDoesNotBlockHeartbeatWriter() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val pong = CountDownLatch(1)
        val worker = CompanionControlQueue<String>("operation", dispatch = {
            started.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS))
        }, failed = { throw AssertionError(it) })
        val writer = CompanionControlQueue<String>("writer", dispatch = { if (it == "PONG:42") pong.countDown() },
            failed = { throw AssertionError(it) })
        try {
            assertTrue(worker.offer("START", 10))
            assertTrue(started.await(1, TimeUnit.SECONDS))
            assertTrue(writer.offer("PONG:42", 10, priority = true))
            assertTrue(pong.await(200, TimeUnit.MILLISECONDS))
        } finally {
            worker.closeAdmission(); writer.closeAdmission(); unblock.countDown()
            worker.awaitSettled(); writer.awaitSettled()
        }
    }

    @Test fun ordinaryOperationsStayOrderedAndPongOnlyOvertakesBetweenWholeFrames() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val finished = CountDownLatch(4)
        val values = Collections.synchronizedList(mutableListOf<String>())
        val queue = CompanionControlQueue<String>("frames", dispatch = {
            if (it == "frame1") { started.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS)) }
            values += "$it:start"; values += "$it:end"; finished.countDown()
        }, failed = { throw AssertionError(it) })
        try {
            assertTrue(queue.offer("frame1", 10)); assertTrue(started.await(1, TimeUnit.SECONDS))
            assertTrue(queue.offer("frame2", 10)); assertTrue(queue.offer("frame3", 10))
            assertTrue(queue.offer("pong", 10, priority = true)); unblock.countDown()
            assertTrue(finished.await(1, TimeUnit.SECONDS))
            assertEquals(listOf("frame1:start", "frame1:end", "pong:start", "pong:end",
                "frame2:start", "frame2:end", "frame3:start", "frame3:end"), values)
        } finally { queue.closeAdmission(); unblock.countDown(); queue.awaitSettled() }
    }

    @Test fun runningAndQueuedOperationsShareByteAndCountBudgets() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val queue = CompanionControlQueue<Int>("bounded", maxItems = 2, maxBytes = 10, dispatch = {
            started.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS))
        }, failed = { throw AssertionError(it) })
        try {
            assertFalse(queue.offer(0, 11)); assertTrue(queue.offer(1, 6))
            assertTrue(started.await(1, TimeUnit.SECONDS))
            assertFalse(queue.offer(2, 5)); assertTrue(queue.offer(2, 4)); assertFalse(queue.offer(3, 0))
            // Heartbeats retain a separate small reserve when ordinary bytes are full.
            assertTrue(queue.offer(4, 1, priority = true))
            assertFalse(queue.offer(5, 2048, priority = true))
        } finally { queue.closeAdmission(); unblock.countDown(); queue.awaitSettled() }
    }

    @Test fun eofDropsQueuedWorkButWaitsForRunningMutationWithoutInterruptingIt() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val settled = AtomicBoolean()
        val values = Collections.synchronizedList(mutableListOf<Int>())
        val queue = CompanionControlQueue<Int>("retire", dispatch = {
            values += it; started.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS)); settled.set(true)
        }, failed = { throw AssertionError(it) })
        try {
            queue.offer(1, 1); assertTrue(started.await(1, TimeUnit.SECONDS)); queue.offer(2, 1)
            queue.closeAdmission()
            assertFalse(queue.offer(3, 1)); assertFalse(settled.get())
            unblock.countDown(); queue.awaitSettled()
            assertTrue(settled.get()); assertEquals(listOf(1), values)
        } finally { queue.closeAdmission(); unblock.countDown(); queue.awaitSettled() }
    }

    @Test fun authorityIsRecheckedBeforeQueuedOperationRuns() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val authorized = AtomicBoolean(true)
        val values = Collections.synchronizedList(mutableListOf<Int>())
        val failed = CountDownLatch(1)
        val queue = CompanionControlQueue<Int>("authority", authorized = authorized::get, dispatch = {
            values += it; started.countDown(); assertTrue(unblock.await(2, TimeUnit.SECONDS))
        }, failed = { failed.countDown() })
        try {
            queue.offer(1, 1); assertTrue(started.await(1, TimeUnit.SECONDS)); queue.offer(2, 1)
            authorized.set(false); unblock.countDown()
            assertTrue(failed.await(1, TimeUnit.SECONDS)); queue.awaitSettled()
            assertEquals(listOf(1), values); assertFalse(queue.offer(3, 1))
        } finally { queue.closeAdmission(); unblock.countDown(); queue.awaitSettled() }
    }
}
