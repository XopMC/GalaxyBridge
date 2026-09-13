package com.xopmc.galaxybridge.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.xopmc.galaxybridge.MainActivity
import com.xopmc.galaxybridge.R

internal const val SERVICE_CHANNEL_ID = "galaxybridge.connection"
internal const val CAPTURE_CHANNEL_ID = "galaxybridge.capture"
internal const val CAMERA_CHANNEL_ID = "galaxybridge.camera"
internal const val CAMERA_CONFIRMATION_CHANNEL_ID = "galaxybridge.camera.confirmation"

internal fun Context.ensureNotificationChannels() {
    val manager = getSystemService(NotificationManager::class.java)
    manager.createNotificationChannels(
        listOf(
            NotificationChannel(
                SERVICE_CHANNEL_ID,
                getString(R.string.service_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = getString(R.string.service_channel_description) },
            NotificationChannel(
                CAPTURE_CHANNEL_ID,
                getString(R.string.capture_notification_title),
                NotificationManager.IMPORTANCE_LOW,
            ),
            NotificationChannel(
                CAMERA_CHANNEL_ID,
                getString(R.string.camera_notification_title),
                NotificationManager.IMPORTANCE_LOW,
            ),
            NotificationChannel(
                CAMERA_CONFIRMATION_CHANNEL_ID,
                getString(R.string.camera_confirmation_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = getString(R.string.camera_confirmation_channel_description) },
        ),
    )
}

internal fun Context.serviceNotification(capture: Boolean = false): Notification {
    ensureNotificationChannels()
    val contentIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
    return Notification.Builder(this, if (capture) CAPTURE_CHANNEL_ID else SERVICE_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
        .setContentTitle(getString(if (capture) R.string.capture_notification_title else R.string.service_notification_title))
        .setContentText(getString(if (capture) R.string.capture_notification_text else R.string.service_notification_text))
        .setContentIntent(contentIntent)
        .setOngoing(true)
        .build()
}

internal fun Context.cameraNotification(): Notification {
    ensureNotificationChannels()
    val contentIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
    return Notification.Builder(this, CAMERA_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.presence_video_online)
        .setContentTitle(getString(R.string.camera_notification_title))
        .setContentText(getString(R.string.camera_notification_text))
        .setContentIntent(contentIntent)
        .setOngoing(true)
        .build()
}
