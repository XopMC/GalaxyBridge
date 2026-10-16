package com.xopmc.galaxybridge.service

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Base64
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID

/** Internal hardware-QA entry point; third-party apps cannot hold DUMP. */
class ClipboardQaReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SET_CLIPBOARD) return
        val image = intent.getStringExtra("png_b64")
        if (image != null) {
            val bytes = runCatching { Base64.decode(image, Base64.DEFAULT) }.getOrNull()
            if (bytes == null || !ClipboardImageCodec.isSafePng(bytes)) {
                resultCode = RESULT_INVALID_PAYLOAD
                resultData = "invalid_image"
                return
            }
            val directory = File(context.cacheDir, "clipboard").apply { mkdirs() }
            val file = File(directory, "audit-${UUID.randomUUID()}.png").apply { writeBytes(bytes) }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            context.getSystemService(ClipboardManager::class.java)
                .setPrimaryClip(ClipData.newUri(context.contentResolver, "Galaxy Bridge QA", uri))
            resultCode = RESULT_OK
            resultData = "image_delivered"
            return
        }
        val text = intent.getStringExtra(EXTRA_TEXT_BASE64)?.let(RemoteTextPayload::decode)
        if (text == null) {
            resultCode = RESULT_INVALID_PAYLOAD
            resultData = "invalid_payload"
            return
        }
        context.getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData.newPlainText("Galaxy Bridge QA", text))
        resultCode = RESULT_OK
        resultData = "delivered"
    }

    companion object {
        const val ACTION_SET_CLIPBOARD = "com.xopmc.galaxybridge.QA_SET_CLIPBOARD"
        const val EXTRA_TEXT_BASE64 = "text_b64"
        private const val RESULT_OK = 0
        private const val RESULT_INVALID_PAYLOAD = 2
    }
}
