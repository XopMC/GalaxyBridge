package com.xopmc.galaxybridge.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.role.RoleManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.CallLog
import android.telecom.TelecomManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import com.xopmc.galaxybridge.protocol.v1.CallEvent
import com.xopmc.galaxybridge.protocol.v1.CallState
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

object CallEventBus {
    private val mutableEvents = MutableSharedFlow<CallEvent>(extraBufferCapacity = 32)
    val events = mutableEvents.asSharedFlow()
    internal fun emit(event: CallEvent) { mutableEvents.tryEmit(event) }
}

object TelephonyBridge {
    private val started = AtomicBoolean(false)
    private var callback: TelephonyCallback? = null

    fun start(context: Context) {
        if (!started.compareAndSet(false, true)) return
        val app = context.applicationContext
        val nextCallback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
            override fun onCallStateChanged(state: Int) {
                CallEventBus.emit(
                    CallEvent.newBuilder()
                        .setCallId(UUID.randomUUID().toString())
                        .setState(
                            when (state) {
                                TelephonyManager.CALL_STATE_RINGING -> CallState.CALL_STATE_RINGING
                                TelephonyManager.CALL_STATE_OFFHOOK -> CallState.CALL_STATE_ACTIVE
                                else -> CallState.CALL_STATE_IDLE
                            },
                        )
                        .setIncoming(state == TelephonyManager.CALL_STATE_RINGING)
                        .setTimestampUnixMs(System.currentTimeMillis())
                        .build(),
                )
            }
        }
        callback = nextCallback
        runCatching {
            app.getSystemService(TelephonyManager::class.java)
                .registerTelephonyCallback(Executor(Runnable::run), nextCallback)
        }
    }

    fun stop(context: Context) {
        if (!started.compareAndSet(true, false)) return
        callback?.let { runCatching { context.getSystemService(TelephonyManager::class.java).unregisterTelephonyCallback(it) } }
        callback = null
    }

    fun recentCalls(context: Context, limit: Int = 100): List<CallEvent> {
        if (!hasDialerRole(context) ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED
        ) return emptyList()
        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.CACHED_NAME,
            CallLog.Calls.DATE,
            CallLog.Calls.DURATION,
            CallLog.Calls.TYPE,
        )
        return runCatching {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                projection,
                null,
                null,
                "${CallLog.Calls.DATE} DESC LIMIT ${limit.coerceIn(1, 500)}",
            )?.use { cursor ->
                buildList {
                    while (cursor.moveToNext()) {
                        val type = cursor.getInt(5)
                        add(
                            CallEvent.newBuilder()
                                .setCallId("history:${cursor.getString(0)}")
                                .setAddress(cursor.getString(1).orEmpty())
                                .setDisplayName(cursor.getString(2).orEmpty())
                                .setState(CallState.CALL_STATE_ENDED)
                                .setIncoming(type != CallLog.Calls.OUTGOING_TYPE)
                                .setTimestampUnixMs(cursor.getLong(3))
                                .setDurationSeconds(cursor.getLong(4).coerceAtLeast(0).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                                .setHistory(true)
                                .build(),
                        )
                    }
                }
            }.orEmpty()
        }.getOrDefault(emptyList())
    }

    @SuppressLint("MissingPermission")
    fun handleCall(context: Context, event: CallEvent): Boolean {
        if (!hasDialerRole(context)) return false
        val telecom = context.getSystemService(TelecomManager::class.java)
        return runCatching {
            when (event.state) {
                CallState.CALL_STATE_DIALING -> {
                    if (event.address.isBlank()) return false
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
                        return false
                    }
                    telecom.placeCall(Uri.fromParts("tel", event.address, null), Bundle())
                }
                CallState.CALL_STATE_ACTIVE -> return GalaxyInCallService.answer(event.callId.takeIf(String::isNotBlank))
                CallState.CALL_STATE_ENDED -> return GalaxyInCallService.end(event.callId.takeIf(String::isNotBlank))
                else -> return false
            }
            true
        }.getOrDefault(false)
    }

    fun hasDialerRole(context: Context): Boolean =
        context.getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_DIALER)
}
