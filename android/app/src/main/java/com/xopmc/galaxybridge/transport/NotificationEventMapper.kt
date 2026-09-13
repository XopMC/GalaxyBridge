package com.xopmc.galaxybridge.transport

import com.google.protobuf.ByteString
import com.xopmc.galaxybridge.protocol.v1.NotificationActionDescriptor
import com.xopmc.galaxybridge.protocol.v1.NotificationEvent
import com.xopmc.galaxybridge.service.BridgeNotification

internal object NotificationEventMapper {
    fun toProtocol(
        notification: BridgeNotification,
        isInitialSnapshot: Boolean = false,
    ): NotificationEvent {
        val builder = NotificationEvent.newBuilder()
            .setNotificationId(notification.key)
            .setPackageName(notification.packageName)
            .setAppLabel(notification.appLabel)
            .setTitle(notification.title)
            .setBody(notification.text)
            .setPostedAtUnixMs(notification.postedAtMillis)
            .setRemoved(notification.removed)
            .setInitialSnapshot(isInitialSnapshot)
            .addAllActions(
                notification.actions.map { action ->
                    NotificationActionDescriptor.newBuilder()
                        .setActionId(action.id)
                        .setTitle(action.title)
                        .setAcceptsText(action.acceptsText)
                        .build()
                },
            )
        notification.appIconPng?.let { builder.setAppIconPng(ByteString.copyFrom(it)) }
        return builder.build()
    }
}
