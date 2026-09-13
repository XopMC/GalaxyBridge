package com.xopmc.galaxybridge.service

import org.junit.Assert.*
import org.junit.Test

class RemoteInputCompletionQueueTest {
    private val tap = AndroidInputCommand.Tap(.5, .5, 1)
    private val text = AndroidInputCommand.Text("Привет e\u0301😀", 1)
    private val enter = AndroidInputCommand.Key(66, 0, 1)
    private class Harness(maxCommands: Int = 128, maxTextBytes: Int = 65_536) {
        val delivered = mutableListOf<AndroidInputCommand>()
        val tickets = mutableListOf<Long>()
        val deadlines = mutableMapOf<Long, Long>()
        var reject = false
        val queue = RemoteInputCompletionQueue(
            execute = { command, ticket ->
                delivered += command
                tickets += ticket
                when {
                    reject -> RemoteInputCompletionQueue.Execution.Rejected
                    command is AndroidInputCommand.Tap || command is AndroidInputCommand.Scroll || command is AndroidInputCommand.Swipe ->
                        RemoteInputCompletionQueue.Execution.Gesture(1_120)
                    else -> RemoteInputCompletionQueue.Execution.Completed
                }
            },
            scheduleTimeout = { ticket, delay -> deadlines[ticket] = delay },
            cancelTimeout = { deadlines.remove(it) },
            maxCommands = maxCommands,
            maxTextBytes = maxTextBytes,
        )
    }
    @Test fun tapTextEnterWaitsForRealGestureCompletion() {
        val h = Harness()
        h.queue.enqueue(tap); h.queue.enqueue(text); h.queue.enqueue(enter)
        assertEquals(listOf(tap), h.delivered)
        h.queue.completed(h.tickets.first(), true)
        assertEquals(listOf(tap, text, enter), h.delivered)
        assertTrue(h.deadlines.isEmpty())
        assertTrue(h.queue.isIdle)
    }
    @Test fun scrollAndTapUseTheSameCompletionBarrier() {
        val h = Harness()
        val scroll = AndroidInputCommand.Scroll(.5,.5,0.0,1.0,1)
        h.queue.enqueue(scroll); h.queue.enqueue(tap); h.queue.enqueue(text)
        h.queue.completed(h.tickets.first(), true)
        assertEquals(listOf(scroll,tap), h.delivered)
        h.queue.completed(h.tickets.last(), true)
        assertEquals(listOf(scroll,tap,text), h.delivered)
    }
    @Test fun onlyAdjacentScrollCommandsCoalesceWithoutCrossingText() {
        val h = Harness()
        val scroll = AndroidInputCommand.Scroll(.5,.5,0.0,1.0,1)
        h.queue.enqueue(tap)
        h.queue.enqueue(scroll); h.queue.enqueue(scroll)
        h.queue.enqueue(text); h.queue.enqueue(scroll)
        h.queue.completed(h.tickets.first(),true)
        assertEquals(listOf(tap,scroll.copy(scrollY=2.0)),h.delivered)
        h.queue.completed(h.tickets.last(),true)
        assertEquals(listOf(tap,scroll.copy(scrollY=2.0),text,scroll),h.delivered)
    }
    @Test fun cancelledGestureDiscardsDependentTextAndEnter() {
        val h = Harness()
        h.queue.enqueue(tap); h.queue.enqueue(text); h.queue.enqueue(enter)
        h.queue.completed(h.tickets.first(), false)
        assertEquals(listOf(tap), h.delivered)
        assertTrue(h.queue.isIdle)
    }
    @Test fun timeoutDoesNotUnlockAnUnsettledGestureAndLateCompletionDoesNotReplay() {
        val h = Harness()
        h.queue.enqueue(tap); h.queue.enqueue(text)
        val old = h.tickets.first()
        h.queue.timeout(old)
        assertFalse(h.queue.enqueue(enter))
        assertFalse(h.queue.isIdle)
        assertEquals(listOf(tap), h.delivered)
        h.queue.completed(old,true)
        assertTrue(h.queue.enqueue(tap))
        h.queue.completed(old,true)
        h.queue.enqueue(text)
        assertEquals(listOf(tap,tap), h.delivered)
        h.queue.completed(h.tickets.last(),true)
        assertEquals(listOf(tap,tap,text), h.delivered)
    }
    @Test fun interruptDiscardsPendingInputAndWaitsForCallback() {
        val h = Harness()
        h.queue.enqueue(tap); h.queue.enqueue(text)
        h.queue.abortPending()
        assertFalse(h.queue.enqueue(enter))
        h.queue.completed(h.tickets.first(),false)
        assertTrue(h.queue.enqueue(text))
        assertEquals(listOf(tap,text),h.delivered)
    }
    @Test fun disconnectNeverFlushesTextAndStaleCallbacksCannotTouchNewLease() {
        val h = Harness()
        h.queue.enqueue(tap); h.queue.enqueue(text)
        h.queue.close()
        assertTrue(h.deadlines.isEmpty())
        assertFalse(h.queue.enqueue(enter))
        h.deadlines[1] = 999 // a new service owns a same-numbered timer
        h.queue.completed(1,true)
        h.queue.timeout(1)
        assertEquals(999L,h.deadlines[1])
        assertEquals(listOf(tap),h.delivered)
    }
    @Test fun boundedQueueRejectsOverflowWithoutExecutingPartialDependentSequence() {
        val h = Harness(maxCommands=1)
        h.queue.enqueue(tap); h.queue.enqueue(text)
        assertFalse(h.queue.enqueue(enter))
        h.queue.completed(h.tickets.first(),true)
        assertEquals(listOf(tap),h.delivered)
        val bytes = Harness(maxTextBytes=3)
        assertFalse(bytes.queue.enqueue(AndroidInputCommand.Text("😀",1)))
        assertTrue(bytes.delivered.isEmpty())
    }
    @Test fun synchronousRejectionDiscardsCommandsWaitingAfterGesture() {
        val h = Harness()
        h.queue.enqueue(tap); h.queue.enqueue(text); h.queue.enqueue(enter)
        h.reject=true
        h.queue.completed(h.tickets.first(),true)
        assertEquals(listOf(tap,text),h.delivered)
        assertTrue(h.queue.isIdle)
    }
    @Test fun immediateCallbackCannotResurrectTimeout() {
        lateinit var queue: RemoteInputCompletionQueue
        val delivered=mutableListOf<AndroidInputCommand>()
        queue=RemoteInputCompletionQueue(
            execute={ command,ticket -> delivered+=command; queue.completed(ticket,true); RemoteInputCompletionQueue.Execution.Gesture(1_000) },
            scheduleTimeout={ _,_ -> fail("Completed gesture must not schedule a timeout") },
            cancelTimeout={},
        )
        queue.enqueue(tap); queue.enqueue(text)
        assertEquals(listOf(tap,text),delivered)
        assertTrue(queue.isIdle)
    }
}
