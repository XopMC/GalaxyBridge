package com.xopmc.galaxybridge.service

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream

internal object NotificationAppIconEncoder {
    const val MAX_PNG_BYTES = 256 * 1024
    private const val ICON_SIZE_PX = 128
    private val pngSignature = byteArrayOf(
        0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    )

    fun load(context: Context, packageName: String): ByteArray? = runCatching {
        val drawable = context.packageManager.getApplicationIcon(packageName)
        val bitmap = Bitmap.createBitmap(ICON_SIZE_PX, ICON_SIZE_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, ICON_SIZE_PX, ICON_SIZE_PX)
        drawable.draw(canvas)
        val encoded = ByteArrayOutputStream().use { output ->
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) return null
            output.toByteArray()
        }
        safePngPayload(encoded)
    }.getOrNull()

    internal fun safePngPayload(data: ByteArray): ByteArray? = data.takeIf {
        it.size in pngSignature.size..MAX_PNG_BYTES &&
            it.copyOfRange(0, pngSignature.size).contentEquals(pngSignature)
    }
}
