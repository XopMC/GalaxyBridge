package com.xopmc.galaxybridge.core

import org.junit.Assert.*
import org.junit.Test

class NotificationListenerRecoveryTest {
    private class Schedule {
        data class Task(val due: Long, val run: () -> Unit, var cancelled: Boolean = false)
        var now = 0L
        val tasks = mutableListOf<Task>()
        fun enqueue(delay: Long, action: () -> Unit): () -> Unit {
            val task = Task(now + delay, action); tasks += task
            return { task.cancelled = true }
        }
        fun advance(to: Long) {
            while (true) {
                val task = tasks.filter { !it.cancelled && it.due <= to }.minByOrNull { it.due } ?: break
                tasks.remove(task); now = task.due; task.run()
            }
            now = to
        }
    }
    @Test fun allowedButDisconnectedListenerRetriesOnBoundedSchedule() {
        val clock = Schedule(); val attempts = mutableListOf<Long>()
        val recovery = NotificationListenerRecovery(
            state = { NotificationListenerRecovery.State(true, true, false) },
            requestBind = { attempts += clock.now }, schedule = clock::enqueue)
        recovery.ownerStarted(); recovery.retry(); recovery.retry()
        clock.advance(100_000)
        assertEquals(listOf(0L, 2_000L, 10_000L, 30_000L), attempts)
        clock.advance(1_000_000); assertEquals(4, attempts.size)
    }
    @Test fun noRequestsWithoutGrantedAccessEnabledFeatureOrWhileAlreadyConnected() {
        for (state in listOf(NotificationListenerRecovery.State(false,true,false),
            NotificationListenerRecovery.State(true,false,false), NotificationListenerRecovery.State(true,true,true))) {
            val clock=Schedule(); var requests=0
            val recovery=NotificationListenerRecovery({state},{requests++},clock::enqueue)
            recovery.ownerStarted(); clock.advance(100_000); assertEquals(0,requests)
        }
    }
    @Test fun connectionCancelsQueuedRetriesAndLaterDisconnectCanRecover() {
        val clock=Schedule(); var connected=false;var requests=0
        val recovery=NotificationListenerRecovery({NotificationListenerRecovery.State(true,true,connected)},{requests++},clock::enqueue)
        recovery.ownerStarted();clock.advance(0);assertEquals(1,requests)
        connected=true;recovery.listenerConnected();clock.advance(100_000);assertEquals(1,requests)
        connected=false;recovery.retry();clock.advance(100_000);assertEquals(2,requests)
    }
    @Test fun revocationAndOwnerStopCannotRebindFromStaleScheduledWork() {
        val clock=Schedule();var granted=true;var requests=0
        val recovery=NotificationListenerRecovery({NotificationListenerRecovery.State(true,granted,false)},{requests++},clock::enqueue)
        recovery.ownerStarted();clock.advance(0);assertEquals(1,requests)
        val stale=clock.tasks.last().run
        granted=false;clock.advance(2_000);assertEquals(1,requests)
        granted=true;recovery.retry();recovery.ownerStopped();stale();clock.advance(100_000)
        assertEquals(1,requests)
    }
    @Test fun featureChangesCancelOldSequenceAndRequestFailuresRemainBounded() {
        val clock=Schedule();var enabled=true;var requests=0
        val recovery=NotificationListenerRecovery({NotificationListenerRecovery.State(enabled,true,false)},
            {requests++;throw IllegalStateException("OS rejected bind")},clock::enqueue)
        recovery.ownerStarted();clock.advance(0);assertEquals(1,requests)
        enabled=false;recovery.featureChanged();clock.advance(100_000);assertEquals(1,requests)
        enabled=true;recovery.featureChanged();clock.advance(200_000);assertEquals(5,requests)
    }
    @Test fun synchronousConnectionDuringRequestCannotScheduleMoreRetries() {
        val clock=Schedule();var requests=0
        lateinit var recovery: NotificationListenerRecovery
        recovery=NotificationListenerRecovery({NotificationListenerRecovery.State(true,true,false)},
            {requests++;recovery.listenerConnected()},clock::enqueue)
        recovery.ownerStarted();clock.advance(100_000);assertEquals(1,requests)
    }
}
