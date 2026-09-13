package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.service.BridgeNotification
import com.xopmc.galaxybridge.service.BridgeNotificationAction
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationEventMapperTest {
    @Test
    fun mapsSourceIconAndInteractiveActionsWithoutChangingContent() {
        val icon = byteArrayOf(0x01, 0x02, 0x03)
        val event = NotificationEventMapper.toProtocol(
            BridgeNotification(
                key = "notification-id",
                packageName = "com.example.messages",
                postedAtMillis = 1234,
                appLabel = "Messages",
                title = "Title",
                text = "Body",
                actions = listOf(
                    BridgeNotificationAction(id = "0", title = "Reply", acceptsText = true),
                ),
                isOngoing = false,
                removed = false,
                appIconPng = icon,
            ),
            isInitialSnapshot = true,
        )

        assertEquals("notification-id", event.notificationId)
        assertEquals("com.example.messages", event.packageName)
        assertEquals("Messages", event.appLabel)
        assertEquals("Title", event.title)
        assertEquals("Body", event.body)
        assertArrayEquals(icon, event.appIconPng.toByteArray())
        assertEquals("0", event.actionsList.single().actionId)
        assertEquals(true, event.actionsList.single().acceptsText)
        assertEquals(true, event.initialSnapshot)
    }
}
