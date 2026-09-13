package com.xopmc.galaxybridge.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Direct-connection text bridge. The receiver exists only in the Internal APK
 * and its manifest requires android.permission.DUMP, which adb shell owns and
 * ordinary third-party applications do not.
 */
class RemoteTextInputReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INJECT_REMOTE_TEXT) return
        val text = intent.getStringExtra(EXTRA_TEXT_BASE64)
            ?.let(RemoteTextPayload::decode)
        if (text == null) {
            resultCode = RESULT_INVALID_PAYLOAD
            resultData = "invalid_payload"
            return
        }
        if (GalaxyAccessibilityService.injectTextImmediately(text)) {
            resultCode = RESULT_OK
            resultData = "delivered"
        } else {
            resultCode = RESULT_ACCESSIBILITY_UNAVAILABLE
            resultData = "accessibility_unavailable"
        }
    }

    companion object {
        const val ACTION_INJECT_REMOTE_TEXT = "com.xopmc.galaxybridge.INJECT_REMOTE_TEXT"
        const val EXTRA_TEXT_BASE64 = "text_b64"
        private const val RESULT_OK = 0
        private const val RESULT_INVALID_PAYLOAD = 2
        private const val RESULT_ACCESSIBILITY_UNAVAILABLE = 3
    }
}
