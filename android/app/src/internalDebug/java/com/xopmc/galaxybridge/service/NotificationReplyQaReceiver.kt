package com.xopmc.galaxybridge.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.xopmc.galaxybridge.BuildConfig
import java.util.UUID
import org.json.JSONObject

/** Shell controller for synthetic notifications. Included in internalDebug only. */
class NotificationReplyQaReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val runId = intent.getStringExtra("run_id")
        if (!fixtureEnabled() || intent.action != ACTION || !validRunId(runId)) {
            resultCode = 2
            resultData = "invalid_qa_request"
            return
        }
        val id = requireNotNull(runId)
        try {
            val report = synchronized(FIXTURE_LOCK) {
                val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                val manager = context.getSystemService(NotificationManager::class.java)
                when (intent.getStringExtra("operation")) {
                    "publish" -> {
                        check(manager.areNotificationsEnabled()) { "notifications_disabled" }
                        val slot = when (intent.getStringExtra("variant") ?: "single") {
                            "single" -> 1
                            "long" -> 2
                            "second" -> 3
                            else -> error("invalid_variant")
                        }
                        manager.createNotificationChannel(NotificationChannel(CHANNEL,
                            "Synthetic notification QA", NotificationManager.IMPORTANCE_DEFAULT))
                        check(manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE) {
                            "qa_channel_disabled"
                        }
                        val key = recordKey(id, slot)
                        check(prefs.edit().putString(key, JSONObject().put("run_id", id)
                            .put("slot", slot).put("reply_count", 0).toString()).commit())
                        val reply = requireNotNull(replyIntent(context, id, slot, PendingIntent.FLAG_UPDATE_CURRENT))
                        val body = if (slot == 2) (1..12).joinToString("\n") {
                            "Synthetic QA line $it: neutral content for notification scrolling and reply acceptance."
                        } else "Synthetic local QA content. Reply stays inside this fixture."
                        val action = Notification.Action.Builder(null, "Reply", reply)
                            .addRemoteInput(RemoteInput.Builder(RESULT_KEY).setLabel("Synthetic reply").build())
                            .setSemanticAction(Notification.Action.SEMANTIC_ACTION_REPLY).build()
                        val notification = Notification.Builder(context, CHANNEL)
                            .setSmallIcon(android.R.drawable.ic_dialog_info)
                            .setContentTitle("Synthetic QA ${if (slot == 3) "second item" else if (slot == 2) "long content" else "reply"}")
                            .setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                            .setSubText("QA $id").setCategory(Notification.CATEGORY_MESSAGE)
                            .setOnlyAlertOnce(true).setAutoCancel(false).addAction(action).build()
                        manager.notify(tag(id), slot, notification)
                        JSONObject().put("status", "published").put("run_id", id).put("slot", slot)
                            .put("package", context.packageName)
                    }
                    "status" -> {
                        val records = org.json.JSONArray()
                        for (slot in 1..3) prefs.getString(recordKey(id, slot), null)?.let {
                            records.put(JSONObject(it))
                        }
                        val activeSlots = org.json.JSONArray()
                        manager.activeNotifications.filter { it.tag == tag(id) && it.id in 1..3 }
                            .sortedBy { it.id }.forEach { activeSlots.put(it.id) }
                        JSONObject().put("status", "reported").put("run_id", id).put("records", records)
                            .put("active_slots", activeSlots)
                    }
                    "invalidate_reply" -> {
                        // Keep the synthetic notifications visible so the host can exercise
                        // the real canceled-PendingIntent error acknowledgement path.
                        for (slot in 1..3) {
                            replyIntent(context, id, slot, PendingIntent.FLAG_NO_CREATE)?.cancel()
                        }
                        JSONObject().put("status", "reply_tokens_invalidated").put("run_id", id)
                    }
                    "dismiss", "reset", "cleanup" -> {
                        val clear = intent.getStringExtra("operation") != "dismiss"
                        val edit = prefs.edit()
                        for (slot in 1..3) {
                            manager.cancel(tag(id), slot)
                            replyIntent(context, id, slot, PendingIntent.FLAG_NO_CREATE)?.cancel()
                            if (clear) edit.remove(recordKey(id, slot))
                        }
                        if (clear) check(edit.commit())
                        JSONObject().put("status", if (clear) "cleaned" else "dismissed").put("run_id", id)
                    }
                    else -> error("invalid_operation")
                }
            }
            resultCode = 0
            resultData = report.toString()
        } catch (error: Exception) {
            resultCode = 3
            resultData = JSONObject().put("status", "failed").put("error", error.javaClass.simpleName)
                .put("detail", error.message).toString()
        }
    }

    companion object {
        const val ACTION = "com.xopmc.galaxybridge.QA_NOTIFICATION_REPLY"
    }
}

/** Receives only the explicit PendingIntent created above; no network or messaging API. */
class NotificationReplyQaResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!fixtureEnabled() || intent.action != REPLY_ACTION) return
        val runId = intent.getStringExtra("run_id") ?: return
        val slot = intent.getIntExtra("slot", 0)
        if (!validRunId(runId) || slot !in 1..3 || intent.data != replyUri(runId, slot)) return
        val reply = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(RESULT_KEY)?.toString() ?: return
        synchronized(FIXTURE_LOCK) {
            val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val key = recordKey(runId, slot)
            val previous = prefs.getString(key, null) ?: return
            val record = JSONObject(previous).put("reply", reply)
                .put("reply_count", JSONObject(previous).optInt("reply_count") + 1)
                .put("received_at_ms", System.currentTimeMillis())
            // Commit before returning so the subsequent shell status is a durable receipt.
            check(prefs.edit().putString(key, record.toString()).commit())
        }
    }
}

private const val PREFERENCES = "notification-reply-qa"
private const val CHANNEL = "notification-reply-qa"
private const val RESULT_KEY = "synthetic_qa_reply"
private const val REPLY_ACTION = "com.xopmc.galaxybridge.QA_NOTIFICATION_REPLY_RESULT"
private val FIXTURE_LOCK = Any()
private fun fixtureEnabled() = BuildConfig.DEBUG && BuildConfig.DISTRIBUTION == "internal"
private fun validRunId(id: String?) = id != null && runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)
private fun tag(runId: String) = "notification-reply-qa:$runId"
private fun recordKey(runId: String, slot: Int) = "$runId:$slot"
private fun replyUri(runId: String, slot: Int) = Uri.parse("galaxybridge-qa://notification-reply/$runId/$slot")
private fun replyIntent(context: Context, runId: String, slot: Int, flag: Int): PendingIntent? =
    PendingIntent.getBroadcast(context, slot,
        Intent(context, NotificationReplyQaResultReceiver::class.java).setAction(REPLY_ACTION)
            .setData(replyUri(runId, slot)).putExtra("run_id", runId).putExtra("slot", slot),
        flag or PendingIntent.FLAG_MUTABLE)
