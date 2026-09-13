package com.xopmc.galaxybridge.service

import android.Manifest
import android.app.Service
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import com.xopmc.galaxybridge.core.PairingUriCodec
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.setup.DistributionFeatures
import com.xopmc.galaxybridge.transport.CompanionLanServer
import com.xopmc.galaxybridge.transport.PairingClient
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class GalaxyBridgeForegroundService : Service() {
    private var lanServer: CompanionLanServer? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pairingWorkerRunning = AtomicBoolean(false)
    private val pairingPreferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { preferences, key ->
        if (key == PENDING_PAIRING) preferences.getString(key, null)?.let(::beginPairing)
    }

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIFICATION_ID, serviceNotification())
        if (DistributionFeatures.telephonyEnabled(BuildConfig.DISTRIBUTION)) {
            TelephonyBridge.start(applicationContext)
        }
        startLanServerIfAllowed()
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        preferences.registerOnSharedPreferenceChangeListener(pairingPreferenceListener)
        preferences.getString(PENDING_PAIRING, null)?.let(::beginPairing)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_TRUST_REVOKED) restartLanServer()
        requestPendingPairing()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        lanServer?.stop()
        lanServer = null
        getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            .unregisterOnSharedPreferenceChangeListener(pairingPreferenceListener)
        scope.cancel()
        if (DistributionFeatures.telephonyEnabled(BuildConfig.DISTRIBUTION)) {
            TelephonyBridge.stop(applicationContext)
        }
        super.onDestroy()
    }

    private fun beginPairing(uri: String) {
        if (!pairingWorkerRunning.compareAndSet(false, true)) return
        scope.launch {
            try {
                pendingPairingRunner().run(uri)
            } finally {
                pairingWorkerRunning.set(false)
                if (scope.isActive) requestPendingPairing()
            }
        }
    }

    private fun requestPendingPairing() {
        getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            .getString(PENDING_PAIRING, null)
            ?.let(::beginPairing)
    }

    private fun pendingPairingRunner() = PendingPairingRunner(
        attempt = { uri ->
            PairingClient(applicationContext).pair(uri).also { succeeded ->
                if (!succeeded) Log.w(TAG, "Pairing attempt failed; retrying while the request is valid")
            }
        },
        currentPending = {
            getSharedPreferences(PREFERENCES, MODE_PRIVATE).getString(PENDING_PAIRING, null)
        },
        expiresAtMillis = { uri, nowMillis ->
            PairingUriCodec.decode(uri, nowMillis / 1_000).expiresAtEpochSeconds * 1_000
        },
        nowMillis = System::currentTimeMillis,
        wait = { delay(it) },
        clearPendingIfCurrent = { uri ->
            withContext(Dispatchers.Main.immediate) {
                val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
                if (preferences.getString(PENDING_PAIRING, null) == uri) {
                    preferences.edit { remove(PENDING_PAIRING) }
                }
            }
        },
    )

    private fun restartLanServer() {
        lanServer?.stop()
        lanServer = null
        startLanServerIfAllowed()
    }

    private fun startLanServerIfAllowed() {
        val hasAccess = Build.VERSION.SDK_INT < 37 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
        if (hasAccess) lanServer = CompanionLanServer(applicationContext).also { it.start() }
    }

    companion object {
        const val ACTION_TRUST_REVOKED = "com.xopmc.galaxybridge.action.TRUST_REVOKED"
        const val NOTIFICATION_ID = 4_701
        const val PREFERENCES = "galaxybridge"
        const val PENDING_PAIRING = "pending_pairing"
        private const val TAG = "GalaxyBridgePairing"
    }
}
