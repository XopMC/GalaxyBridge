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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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

sealed interface NotificationDelivery

data class NotificationEmission(
    val notification: BridgeNotification,
    val isInitialSnapshot: Boolean,
) : NotificationDelivery

data class NotificationSnapshotBoundary(val complete: Boolean) : NotificationDelivery

class NotificationBacklogOverflowException : IllegalStateException("Notification subscriber backlog exceeded; reconnect for an authoritative snapshot")

object NotificationEventBus {
    private class Subscription {
        val channel = Channel<BridgeNotification>(128)
        val overflow = CompletableDeferred<NotificationBacklogOverflowException>()
    }

    private val nextSubscriptionId = AtomicLong()
    private val activeNotifications = linkedMapOf<String, BridgeNotification>()
    private val subscriptions = linkedMapOf<Long, Subscription>()

    // Compatibility view for consumers interested only in notification rows.
    val events: Flow<NotificationEmission> get() = deliveries.filterIsInstance<NotificationEmission>()

    val deliveries: Flow<NotificationDelivery> get() = deliveries {}

    fun deliveries(onOverflow: () -> Unit): Flow<NotificationDelivery> = flow {
        coroutineScope {
            val subscriptionId = nextSubscriptionId.incrementAndGet()
            val subscription = Subscription()
            val channel = subscription.channel
            // Failure must reach merge even while emit is suspended behind a slow
            // transport, rather than waiting for another receive from the channel.
            val overflowWatcher = launch(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
                throw subscription.overflow.await()
            }
            val snapshot = synchronized(activeNotifications) {
                subscriptions[subscriptionId] = subscription
                activeNotifications.values.sortedWith(
                    compareByDescending<BridgeNotification> { it.postedAtMillis }.thenBy { it.key },
                )
            }
            try {
                emit(NotificationSnapshotBoundary(complete = false))
                snapshot.forEach { emit(NotificationEmission(it, isInitialSnapshot = true)) }
                emit(NotificationSnapshotBoundary(complete = true))
                for (notification in channel) {
                    emit(NotificationEmission(notification, isInitialSnapshot = false))
                }
            } catch (failure: CancellationException) {
                // Channel.cancel discards retained icons/backlog immediately. A plain
                // cancellation would silently finish this child of merge without
                // failing the socket, so expose overflow as a transport failure.
                val overflow = failure.cause as? NotificationBacklogOverflowException
                if (overflow != null) throw overflow
                throw failure
            } finally {
                overflowWatcher.cancel()
                if (subscription.overflow.isCompleted) {
                    // Either the channel receiver or the watcher may observe the
                    // failure first. Cleanup owns the close exactly once, so an
                    // early receiver cannot cancel the watcher before it closes
                    // a synchronous socket write. Cancellation must not skip it.
                    withContext(NonCancellable + Dispatchers.IO) { runCatching(onOverflow) }
                }
                synchronized(activeNotifications) {
                    subscriptions.remove(subscriptionId)?.channel?.cancel()
                }
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
            subscriptions.forEach { (id, subscription) ->
                val channel = subscription.channel
                val sent = channel.trySend(notification)
                if (sent.isFailure) {
                    if (!sent.isClosed) {
                        val overflow = NotificationBacklogOverflowException()
                        // Publish before waking a cancelled receiver: its cleanup
                        // must know that transport closure is required.
                        subscription.overflow.complete(overflow)
                        channel.cancel(CancellationException("Notification backlog overflow").apply {
                            initCause(overflow)
                        })
                    }
                    closed += id
                }
            }
            closed.forEach { subscriptions.remove(it)?.channel?.cancel() }
        }
    }

    internal fun discardAll() {
        synchronized(activeNotifications) {
            activeNotifications.clear()
            // Drop retained PHI and already-queued rows immediately while preserving
            // the authenticated event channel for capability and policy changes.
            subscriptions.values.forEach { subscription -> while (subscription.channel.tryReceive().isSuccess) { } }
        }
    }

    internal fun replaceActiveNotifications(notifications: List<BridgeNotification>) {
        synchronized(activeNotifications) {
            val currentKeys = notifications.filterNot { it.removed }.mapTo(hashSetOf()) { it.key }
            val missedRemovals = activeNotifications.values.filter { it.key !in currentKeys }
            missedRemovals.forEach { emit(it.copy(removed = true, appIconPng = null)) }
            notifications.filterNot { it.removed }.forEach(::emit)
        }
    }
}

class GalaxyNotificationListenerService : NotificationListenerService() {
    private val rawNotifications = linkedMapOf<String, StatusBarNotification>()
    private val pendingRemovals = mutableSetOf<String>()
    private val presentation = NotificationPresentationState<BridgeNotification> { previous, row ->
        previous.copy(appIconPng = null) == row.copy(appIconPng = null) &&
            previous.appIconPng.contentEquals(row.appIconPng)
    }

    private fun notificationsEnabled(): Boolean = com.xopmc.galaxybridge.setup.DeviceFeaturePreferences(this).isEnabled("notifications")
    private fun clearFeatureSnapshot() {
        rawNotifications.clear(); pendingRemovals.clear(); presentation.clear(); NotificationEventBus.discardAll()
    }
    private fun applyFeaturePolicy() {
        if (!notificationsEnabled()) clearFeatureSnapshot() else onListenerConnected()
    }

    override fun onListenerConnected() {
        active.set(this)
        NotificationListenerConnectionRecovery.listenerConnected()
        if (!notificationsEnabled()) { clearFeatureSnapshot(); return }
        // A listener may have missed removals while Android had it disconnected.
        // Failed OS reads must not be mistaken for an authoritative empty list.
        val current = runCatching { activeNotifications.toList() }.getOrNull() ?: return
        pendingRemovals.clear()
        rawNotifications.clear()
        current.associateByTo(rawNotifications) { it.key }
        presentation.clear()
        reconcilePresentation(authoritative = true)
    }

    override fun onListenerDisconnected() {
        if (active.compareAndSet(this, null)) NotificationListenerConnectionRecovery.retry()
    }

    override fun onDestroy() {
        if (active.compareAndSet(this, null)) NotificationListenerConnectionRecovery.retry()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!notificationsEnabled()) { clearFeatureSnapshot(); return }
        refreshNotifications()
        pendingRemovals.remove(sbn.key)
        rawNotifications[sbn.key] = sbn
        // A posted notification can mutate extras without changing its SBN identity.
        reconcilePresentation(invalidated = setOf(sbn.key))
    }

    override fun onNotificationRankingUpdate(rankingMap: RankingMap) {
        if (!notificationsEnabled()) { clearFeatureSnapshot(); return }
        // Android may change overrideGroupKey while regrouping existing children.
        refreshNotifications()
        reconcilePresentation()
    }

    private fun refreshNotifications() {
        if (!notificationsEnabled()) { clearFeatureSnapshot(); return }
        val current = runCatching { activeNotifications.toList() }.getOrNull() ?: return
        val keys = current.mapTo(hashSetOf()) { it.key }
        pendingRemovals.retainAll(keys)
        rawNotifications.clear()
        current.filterNot { it.key in pendingRemovals }.associateByTo(rawNotifications) { it.key }
    }

    @Suppress("DEPRECATION")
    private fun reconcilePresentation(authoritative: Boolean = false, invalidated: Set<String> = emptySet()) {
        if (!notificationsEnabled()) { clearFeatureSnapshot(); return }
        val converted = presentation.payloads(rawNotifications.keys, invalidated) { key ->
            toBridgeNotification(rawNotifications.getValue(key))
        }
        val facts = rawNotifications.values.map { sbn ->
            val convertedRow = converted.getValue(sbn.key)
            val notification = sbn.notification
            NotificationGroupFacts(
                key = sbn.key,
                packageName = sbn.packageName,
                userId = sbn.userId,
                groupKey = if (sbn.isGroup) sbn.groupKey else null,
                isSummary = notification.flags and Notification.FLAG_GROUP_SUMMARY != 0,
                hasDistinctContent = convertedRow.text.isNotBlank() ||
                    convertedRow.title.let { it.isNotBlank() && it != convertedRow.appLabel } ||
                    convertedRow.actions.isNotEmpty() || notification.contentView != null ||
                    notification.bigContentView != null || notification.headsUpContentView != null,
                number = notification.number,
            )
        }
        val visibleKeys = NotificationGroupPresentation.visibleKeys(facts)
        val delta = presentation.present(visibleKeys)
        // Removal emissions purge an already-present summary from subscriber snapshots.
        // Retaining its raw SBN lets it reappear when its last represented child leaves.
        if (authoritative) {
            delta.visible.values.forEach(::cache)
            NotificationEventBus.replaceActiveNotifications(delta.visible.values.toList())
        } else {
            delta.removed.forEach {
                NotificationEventBus.emit(it.copy(removed = true, appIconPng = null))
            }
            delta.changed.forEach { row ->
                cache(row)
                NotificationEventBus.emit(row)
            }
        }
    }

    @Suppress("DEPRECATION") // Bundle array and legacy sender APIs also support Android 12 MessagingStyle notifications.
    private fun toBridgeNotification(sbn: StatusBarNotification): BridgeNotification {
        val extras = sbn.notification.extras
        val appLabel = runCatching {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        }.getOrDefault(sbn.packageName)
        fun textExtra(key: String) = runCatching { extras.getCharSequence(key) }.getOrNull()
        val messageBundles = runCatching {
            extras.getParcelableArray(Notification.EXTRA_MESSAGES)
                ?: extras.getParcelableArray(Notification.EXTRA_HISTORIC_MESSAGES)
        }.getOrNull().orEmpty().takeLast(NotificationTextExtractor.MAX_ENTRIES)
        val messages = messageBundles.mapNotNull { bundle ->
            // Parse independently so a malformed entry cannot hide valid messages.
            runCatching {
                Notification.MessagingStyle.Message.getMessagesFromBundleArray(arrayOf(bundle)).firstOrNull()?.let {
                    NotificationMessageText(it.senderPerson?.name ?: it.sender, it.text)
                }
            }.getOrNull()
        }
        val content = NotificationTextExtractor.extract(NotificationTextInput(
            appLabel = appLabel,
            title = textExtra(Notification.EXTRA_TITLE),
            bigTitle = textExtra(Notification.EXTRA_TITLE_BIG),
            conversationTitle = textExtra(Notification.EXTRA_CONVERSATION_TITLE),
            text = textExtra(Notification.EXTRA_TEXT),
            bigText = textExtra(Notification.EXTRA_BIG_TEXT),
            textLines = runCatching { extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES) }
                .getOrNull().orEmpty().takeLast(NotificationTextExtractor.MAX_ENTRIES),
            messages = messages,
            subText = textExtra(Notification.EXTRA_SUB_TEXT),
            summaryText = textExtra(Notification.EXTRA_SUMMARY_TEXT),
            ticker = sbn.notification.tickerText,
        ))
        return BridgeNotification(
            key = sbn.key,
            packageName = sbn.packageName,
            postedAtMillis = sbn.postTime,
            appLabel = appLabel,
            title = content.title,
            text = content.body,
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
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (!notificationsEnabled()) { clearFeatureSnapshot(); return }
        refreshNotifications()
        pendingRemovals.add(sbn.key)
        rawNotifications.remove(sbn.key)
        reconcilePresentation()
    }

    fun dismiss(key: String) {
        cancelNotification(key)
    }

    fun invokeAction(key: String, actionIndex: Int, inlineReply: String? = null): Boolean {
        return invokeActionResult(key, actionIndex, inlineReply).accepted
    }

    internal fun invokeActionResult(key: String, actionIndex: Int, inlineReply: String?): NotificationActionExecution {
        val notification = activeNotifications.firstOrNull { it.key == key }
            ?: return NotificationActionExecution(false, "notification_missing")
        val action = notification.notification.actions?.getOrNull(actionIndex)
            ?: return NotificationActionExecution(false, "action_missing")
        val fillIn = Intent()
        if (inlineReply != null) {
            val inputs = action.remoteInputs?.takeIf { it.isNotEmpty() }
                ?: return NotificationActionExecution(false, "reply_unavailable")
            val results = Bundle().apply {
                inputs.forEach { input -> putCharSequence(input.resultKey, inlineReply) }
            }
            RemoteInput.addResultsToIntent(inputs, fillIn, results)
        }
        return try {
            action.actionIntent.send(this, 0, fillIn)
            NotificationActionExecution(true)
        } catch (_: PendingIntent.CanceledException) {
            NotificationActionExecution(false, "pending_intent_canceled")
        } catch (_: Exception) {
            NotificationActionExecution(false, "action_rejected")
        }
    }

    private fun dismissResult(key: String): NotificationActionExecution {
        if (activeNotifications.none { it.key == key }) return NotificationActionExecution(false, "notification_missing")
        return try {
            cancelNotification(key)
            NotificationActionExecution(true)
        } catch (_: Exception) { NotificationActionExecution(false, "action_rejected") }
    }

    private fun cache(notification: BridgeNotification) {
        if (!notificationsEnabled()) return
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
        fun refreshFeaturePolicy() {
            NotificationListenerConnectionRecovery.featureChanged()
            val listener = active.get() ?: return
            // Clear the shared backlog synchronously before sending the policy receipt.
            if (!listener.notificationsEnabled()) NotificationEventBus.discardAll()
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (active.get() === listener) listener.applyFeaturePolicy()
            }
        }

        fun dismissActive(key: String): Boolean = active.get()?.let {
            it.dismiss(key)
            true
        } ?: false

        fun invokeActive(key: String, actionId: String, reply: String?): Boolean =
            active.get()?.invokeAction(key, actionId.toIntOrNull() ?: return false, reply) ?: false

        internal fun performActiveResult(key: String, actionId: String, reply: String?, dismiss: Boolean): NotificationActionExecution {
            val listener = active.get() ?: return NotificationActionExecution(false, "listener_unavailable")
            if (!listener.notificationsEnabled()) return NotificationActionExecution(false, "feature_disabled")
            return try {
                if (dismiss) listener.dismissResult(key) else listener.invokeActionResult(
                    key, actionId.toIntOrNull() ?: return NotificationActionExecution(false, "action_missing"), reply,
                )
            } catch (_: Exception) { NotificationActionExecution(false, "action_rejected") }
        }
    }
}
