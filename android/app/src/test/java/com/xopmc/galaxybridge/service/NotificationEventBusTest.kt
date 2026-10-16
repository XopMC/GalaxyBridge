package com.xopmc.galaxybridge.service

import com.xopmc.galaxybridge.transport.OutboundChannelLifecycle
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.async
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationEventBusTest {
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun overflowClosesTransportEvenDuringABlockedSynchronousWrite() = runBlocking {
        val key = "blocked-transport/${System.nanoTime()}"
        val entered = CompletableDeferred<Unit>()
        val closed = AtomicBoolean()
        val block = CountDownLatch(1)
        val closeTransport = { closed.set(true); block.countDown() }
        val producer = async(Dispatchers.IO) {
            runCatching {
                OutboundChannelLifecycle.run(object : InputStream() {
                    override fun read(): Int { block.await(); return -1 }
                }, closeTransport = closeTransport) {
                    merge(NotificationEventBus.deliveries(onOverflow = closeTransport)).collect { delivery ->
                        if (delivery is NotificationEmission && delivery.notification.key == key) {
                            entered.complete(Unit)
                            block.await() // Models blocking SSLSocket output.write, not coroutine suspension.
                        }
                    }
                }
            }.exceptionOrNull()
        }
        try {
            NotificationEventBus.emit(notification(key, 1, "blocked socket write"))
            withTimeout(2_000) { entered.await() }
            repeat(1_024) { NotificationEventBus.emit(notification(key, it.toLong() + 2, "update-$it")) }
            val failure = withTimeoutOrNull(2_000) { producer.await() }
            assertTrue("Overflow must close the blocked transport before the writer returns", closed.get())
            assertTrue("Overflow must fail the events channel", failure != null && failure !is CancellationException)
        } finally {
            block.countDown()
            producer.cancel()
            NotificationEventBus.emit(notification(key, 2_000, "", removed = true))
        }
    }

    @Test
    fun overflowInterruptsASuspendedSnapshotWithoutWaitingForTheMacToReadAgain() = runBlocking {
        val key = "suspended-overflow/${System.nanoTime()}"
        val entered = CompletableDeferred<Unit>()
        val neverReleased = CompletableDeferred<Unit>()
        val collector = async {
            runCatching {
                NotificationEventBus.events.filter { it.notification.key == key }.collect {
                    entered.complete(Unit)
                    neverReleased.await()
                }
            }.exceptionOrNull()
        }
        kotlinx.coroutines.yield()
        NotificationEventBus.emit(notification(key, 1, "blocked write"))
        entered.await()
        repeat(1_024) { NotificationEventBus.emit(notification(key, it.toLong() + 2, "update-$it")) }
        val failure = withTimeoutOrNull(500) { collector.await() }
        collector.cancel()
        NotificationEventBus.emit(notification(key, 2_000, "", removed = true))
        assertTrue("Overflow must interrupt the suspended producer", failure != null && failure !is CancellationException)
    }

    @Test
    fun listenerReconnectionReplacesStaleActiveRowsAndPublishesMissedRemovals() = runBlocking {
        val key = "listener-reconnect/${System.nanoTime()}"
        NotificationEventBus.emit(notification(key, 1, "was active before listener disconnected"))
        val removal = async {
            withTimeoutOrNull(500) {
                NotificationEventBus.events.filter { it.notification.key == key && !it.isInitialSnapshot }
                    .take(1).toList().single()
            }
        }
        kotlinx.coroutines.yield()
        NotificationEventBus.replaceActiveNotifications(emptyList())
        assertEquals(true, removal.await()?.notification?.removed)
        val replayed = withTimeoutOrNull(50) {
            NotificationEventBus.events.filter { it.notification.key == key }.take(1).toList()
        }
        assertEquals(null, replayed)
    }

    @Test
    fun snapshotBoundariesSurroundCapturedRowsBeforeConcurrentLiveRemoval() = runBlocking {
        val key = "ordered-snapshot/${System.nanoTime()}"
        NotificationEventBus.emit(notification(key, 1, "captured"))
        val received = withTimeoutOrNull(500) {
            NotificationEventBus.deliveries
                .map { delivery ->
                    when (delivery) {
                        is NotificationSnapshotBoundary -> {
                            if (!delivery.complete) NotificationEventBus.emit(notification(key, 2, "", removed = true))
                            if (delivery.complete) "end" else "begin"
                        }
                        is NotificationEmission -> if (delivery.notification.key == key) {
                            "${delivery.isInitialSnapshot}/${delivery.notification.removed}"
                        } else "unrelated"
                    }
                }
                .filter { it != "unrelated" }
                .take(4)
                .toList()
        }
        assertEquals(listOf("begin", "true/false", "end", "false/true"), received)
    }

    @Test
    fun aSlowMacFailsInsteadOfRetainingAnUnlimitedBacklogAndReconnectRecoversRemoval() = runBlocking {
        val key = "overflow/${System.nanoTime()}"
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val healthy = async {
            withTimeoutOrNull(1_000) {
                NotificationEventBus.events.filter { it.notification.key == key }.take(1_026).toList()
            }
        }
        var received = 0
        val collector = async {
            runCatching {
                NotificationEventBus.events.filter { it.notification.key == key }.collect {
                    received += 1
                    if (received == 1) {
                        entered.complete(Unit)
                        release.await()
                    }
                }
            }.exceptionOrNull()
        }
        kotlinx.coroutines.yield()
        NotificationEventBus.emit(notification(key, 1, "first"))
        entered.await()
        repeat(1_024) {
            NotificationEventBus.emit(notification(key, it.toLong() + 2, "update-$it"))
            kotlinx.coroutines.yield()
        }
        NotificationEventBus.emit(notification(key, 2_000, "", removed = true))
        release.complete(Unit)

        val failure = withTimeoutOrNull(1_000) { collector.await() }
        collector.cancel()
        assertTrue("Overflow must fail the transport so it can reconnect", failure != null)
        assertTrue("merge must see an ordinary failure, not child cancellation", failure !is CancellationException)
        assertEquals("Overflow must discard queued stale revisions", 1, received)
        assertEquals("A slow Mac must not interrupt another subscriber", true, healthy.await()?.last()?.notification?.removed)
        val restored = withTimeoutOrNull(50) {
            NotificationEventBus.events.filter { it.notification.key == key }.take(1).toList()
        }
        assertEquals("A removed notification must stay absent after reconnect", null, restored)
    }

    @Test
    fun aNewMacSubscriptionStartsWithEveryCurrentNotificationAtItsLatestRevision() = runBlocking {
        val prefix = "snapshot-revisions/"
        NotificationEventBus.emit(notification("${prefix}older", postedAt = 100, body = "older"))
        NotificationEventBus.emit(notification("${prefix}latest", postedAt = 200, body = "stale"))
        NotificationEventBus.emit(notification("${prefix}latest", postedAt = 300, body = "latest"))

        val received = withTimeoutOrNull(500) {
            NotificationEventBus.events
                .filter { it.notification.key.startsWith(prefix) }
                .take(2)
                .map { Triple(it.notification.key, it.notification.text, it.isInitialSnapshot) }
                .toList()
        }

        assertEquals(
            listOf(
                Triple("${prefix}latest", "latest", true),
                Triple("${prefix}older", "older", true),
            ),
            received,
        )
    }

    @Test
    fun aRemovedNotificationIsNotResurrectedForANewMacSubscription() = runBlocking {
        val prefix = "snapshot-removal/"
        NotificationEventBus.emit(notification("${prefix}removed", postedAt = 100, body = "visible"))
        NotificationEventBus.emit(notification("${prefix}removed", postedAt = 200, body = "", removed = true))
        NotificationEventBus.emit(notification("${prefix}active", postedAt = 300, body = "active"))

        val received = withTimeoutOrNull(500) {
            NotificationEventBus.events
                .filter { it.notification.key.startsWith(prefix) }
                .take(1)
                .map { it.notification.key }
                .toList()
        }

        assertEquals(listOf("${prefix}active"), received)
    }

    @Test
    fun aNotificationPostedAfterSubscriptionIsMarkedLive() = runBlocking {
        val key = "live/${System.nanoTime()}"
        val received = async {
            withTimeoutOrNull(500) {
                NotificationEventBus.events
                    .filter { it.notification.key == key }
                    .take(1)
                    .toList()
                    .single()
            }
        }

        kotlinx.coroutines.yield()
        NotificationEventBus.emit(notification(key, postedAt = 400, body = "live"))

        assertEquals(false, received.await()?.isInitialSnapshot)
    }

    private fun notification(
        key: String,
        postedAt: Long,
        body: String,
        removed: Boolean = false,
    ) = BridgeNotification(
        key = key,
        packageName = "com.example.messages",
        postedAtMillis = postedAt,
        appLabel = "Messages",
        title = "Title",
        text = body,
        actions = emptyList(),
        isOngoing = false,
        removed = removed,
    )
}
