package com.xopmc.galaxybridge.service

import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationEventBusTest {
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
