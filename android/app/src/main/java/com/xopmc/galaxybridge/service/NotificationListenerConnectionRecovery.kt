package com.xopmc.galaxybridge.service

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.util.Log
import com.xopmc.galaxybridge.core.NotificationListenerRecovery
import com.xopmc.galaxybridge.setup.DeviceFeaturePreferences

/** Reconnects this app's already-authorized listener while its foreground owner exists. */
internal object NotificationListenerConnectionRecovery {
    private val handler = Handler(Looper.getMainLooper())
    private var recovery: NotificationListenerRecovery? = null

    fun ownerStarted(context: Context) = onMain {
        if (recovery == null) {
            val app = context.applicationContext
            val component = ComponentName(app, GalaxyNotificationListenerService::class.java)
            recovery = NotificationListenerRecovery(
                state = {
                    NotificationListenerRecovery.State(
                        enabled = DeviceFeaturePreferences(app).isEnabled("notifications"),
                        accessGranted = app.getSystemService(NotificationManager::class.java)
                            .isNotificationListenerAccessGranted(component),
                        connected = GalaxyNotificationListenerService.isActive(),
                    )
                },
                requestBind = {
                    NotificationListenerService.requestRebind(component)
                    Log.i("GalaxyBridge", "Requested existing notification listener connection")
                },
                schedule = { delay, action ->
                    val task = Runnable { action() }
                    check(handler.postDelayed(task, delay))
                    val cancel: () -> Unit = { handler.removeCallbacks(task) }
                    cancel
                },
            )
        }
        recovery?.ownerStarted()
    }
    fun ownerStopped() = onMain { recovery?.ownerStopped(); recovery = null }
    fun retry() = onMain { recovery?.retry() }
    fun listenerConnected() = onMain { recovery?.listenerConnected() }
    fun featureChanged() = onMain { recovery?.featureChanged() }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() === Looper.getMainLooper()) action() else handler.post { action() }
    }
}
