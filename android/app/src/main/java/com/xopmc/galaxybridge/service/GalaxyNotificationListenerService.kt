package com.xopmc.galaxybridge.service

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.xopmc.galaxybridge.storage.EncryptedContentCache
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import org.json.JSONArray
import org.json.JSONObject

data class BridgeNotificationAction(
    val id: String,
    val title: String,
    val acceptsText: Boolean,
)

data class BridgeNotification(
    val key: String,
    val packageName: String,
    val postedAtMillis: Long,
    val appLabel: String,
    val title: String,
    val text: String,
    val actions: List<BridgeNotificationAction>,
    val isOngoing: Boolean,
    val removed: Boolean,
    val appIconPng: ByteArray? = null,
)

data class NotificationEmission(
    val notification: BridgeNotification,
    val isInitialSnapshot: Boolean,
)

object NotificationEventBus {
    private val nextSubscriptionId = AtomicLong()
    private val activeNotifications = linkedMapOf<String, BridgeNotification>()
    private val subscriptions = linkedMapOf<Long, Channel<BridgeNotification>>()

    val events: Flow<NotificationEmission> = flow {
        val subscriptionId = nextSubscriptionId.incrementAndGet()
        val channel = Channel<BridgeNotification>(Channel.UNLIMITED)
        val snapshot = synchronized(activeNotifications) {
            subscriptions[subscriptionId] = channel
            activeNotifications.values.sortedWith(
                compareByDescending<BridgeNotification> { it.postedAtMillis }.thenBy { it.key },
            )
        }
        try {
            snapshot.forEach { emit(NotificationEmission(it, isInitialSnapshot = true)) }
            for (notification in channel) {
                emit(NotificationEmission(notification, isInitialSnapshot = false))
            }
        } finally {
            synchronized(activeNotifications) {
                subscriptions.remove(subscriptionId)?.close()
            }
        }
    }

    internal fun emit(notification: BridgeNotification) {
        synchronized(activeNotifications) {
            if (notification.removed) {
                activeNotifications.remove(notification.key)
            } else {
                activeNotifications[notification.key] = notification
            }
            val closed = mutableListOf<Long>()
            subscriptions.forEach { (id, channel) ->
                if (channel.trySend(notification).isClosed) closed += id
            }
            closed.forEach { subscriptions.remove(it)?.close() }
        }
    }
}

class GalaxyNotificationListenerService : NotificationListenerService() {
    override fun onListenerConnected() {
        active.set(this)
        runCatching { activeNotifications.toList() }
            .getOrDefault(emptyList())
            .forEach(::publish)
    }

    override fun onListenerDisconnected() {
        active.compareAndSet(this, null)
    }

    override fun onDestroy() {
        active.compareAndSet(this, null)
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        publish(sbn)
    }

    private fun publish(sbn: StatusBarNotification) {
        val extras = sbn.notification.extras
        val notification = BridgeNotification(
            key = sbn.key,
            packageName = sbn.packageName,
            postedAtMillis = sbn.postTime,
            appLabel = runCatching {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
            }.getOrDefault(sbn.packageName),
            title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
            text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty(),
            actions = sbn.notification.actions?.mapIndexed { index, action ->
                BridgeNotificationAction(
                    id = index.toString(),
                    title = action.title.toString(),
                    acceptsText = !action.remoteInputs.isNullOrEmpty(),
                )
            }.orEmpty(),
            isOngoing = sbn.isOngoing,
            removed = false,
            appIconPng = NotificationAppIconEncoder.load(this, sbn.packageName),
        )
        cache(notification)
        NotificationEventBus.emit(notification)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        NotificationEventBus.emit(
            BridgeNotification(
                key = sbn.key,
                packageName = sbn.packageName,
                postedAtMillis = System.currentTimeMillis(),
                appLabel = sbn.packageName,
                title = "",
                text = "",
                actions = emptyList(),
                isOngoing = false,
                removed = true,
            ),
        )
    }

    fun dismiss(key: String) {
        cancelNotification(key)
    }

    fun invokeAction(key: String, actionIndex: Int, inlineReply: String? = null): Boolean {
        val action = activeNotifications.firstOrNull { it.key == key }
            ?.notification
            ?.actions
            ?.getOrNull(actionIndex)
            ?: return false
        val fillIn = Intent()
        if (inlineReply != null) {
            val inputs = action.remoteInputs ?: return false
            val results = Bundle().apply {
                inputs.forEach { input -> putCharSequence(input.resultKey, inlineReply) }
            }
            RemoteInput.addResultsToIntent(inputs, fillIn, results)
        }
        return try {
            action.actionIntent.send(this, 0, fillIn)
            true
        } catch (_: PendingIntent.CanceledException) {
            false
        }
    }

    private fun cache(notification: BridgeNotification) {
        val payload = JSONObject()
            .put("package", notification.packageName)
            .put("appLabel", notification.appLabel)
            .put("title", notification.title)
            .put("body", notification.text)
            .put("postedAt", notification.postedAtMillis)
            .put(
                "actions",
                JSONArray().apply {
                    notification.actions.forEach { action ->
                        put(
                            JSONObject()
                                .put("id", action.id)
                                .put("title", action.title)
                                .put("acceptsText", action.acceptsText),
                        )
                    }
                },
            )
            .toString()
            .toByteArray(Charsets.UTF_8)
        val deviceId = getSharedPreferences("galaxybridge", MODE_PRIVATE)
            .getString("device_id", null)
            ?: "local-device"
        runCatching {
            EncryptedContentCache(this).use { cache ->
                cache.put(deviceId, EncryptedContentCache.NAMESPACE_NOTIFICATIONS, notification.key, payload)
                cache.prune()
            }
        }
    }

    companion object {
        private val active = AtomicReference<GalaxyNotificationListenerService?>()

        fun isActive(): Boolean = active.get() != null

        fun dismissActive(key: String): Boolean = active.get()?.let {
            it.dismiss(key)
            true
        } ?: false

        fun invokeActive(key: String, actionId: String, reply: String?): Boolean =
            active.get()?.invokeAction(key, actionId.toIntOrNull() ?: return false, reply) ?: false
    }
}
