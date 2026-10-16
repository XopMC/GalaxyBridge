package com.xopmc.galaxybridge.service

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/** Neutral, foreground image copy/paste acceptance surface. Internal debug only. */
class ClipboardPasteQaActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
            setBackgroundColor(Color.rgb(18, 28, 45))
        }
        val status = TextView(this).apply {
            text = "Galaxy Bridge image clipboard QA\nOnly neutral test images."
            setTextColor(Color.WHITE)
            textSize = 18f
        }
        val image = ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_CENTER }
        fun receipt(operation: String, bytes: ByteArray) {
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            status.text = "$operation: ${bytes.size} bytes\nSHA-256 $digest"
            getSharedPreferences("clipboard_paste_qa", MODE_PRIVATE).edit()
                .putString("operation", operation).putString("sha256", digest).putInt("bytes", bytes.size).commit()
        }
        val copy = Button(this).apply {
            text = "Copy neutral image"
            setOnClickListener {
                val bitmap = Bitmap.createBitmap(512, 320, Bitmap.Config.ARGB_8888)
                Canvas(bitmap).apply {
                    drawColor(Color.rgb(24, 68, 128))
                    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(255, 190, 48) }
                    drawRect(32f, 32f, 160f, 288f, paint)
                    paint.color = Color.WHITE
                    paint.textSize = 30f
                    drawText("Galaxy Bridge", 184f, 130f, paint)
                    paint.textSize = 22f
                    drawText("Image clipboard QA", 184f, 175f, paint)
                }
                val directory = File(cacheDir, "clipboard").apply { mkdirs() }
                val file = File(directory, "acceptance-neutral.png")
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                val uri = FileProvider.getUriForFile(this@ClipboardPasteQaActivity, "$packageName.fileprovider", file)
                getSystemService(ClipboardManager::class.java).setPrimaryClip(
                    ClipData.newUri(contentResolver, "Neutral clipboard QA image", uri))
                image.setImageBitmap(bitmap)
                receipt("copied", file.readBytes())
            }
        }
        val paste = Button(this).apply {
            text = "Paste image from clipboard"
            setOnClickListener {
                runCatching {
                    val clip = getSystemService(ClipboardManager::class.java).primaryClip
                    val uri = requireNotNull(clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri) { "No image URI in clipboard" }
                    val bytes = requireNotNull(contentResolver.openInputStream(uri)).use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (output.size() <= MAX_IMAGE_BYTES) {
                            val count = input.read(buffer, 0, minOf(buffer.size, MAX_IMAGE_BYTES + 1 - output.size()))
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                    require(bytes.size <= MAX_IMAGE_BYTES) { "Image exceeds QA limit" }
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                    require(bounds.outWidth > 0 && bounds.outHeight > 0 &&
                        bounds.outWidth.toLong() * bounds.outHeight <= 16_000_000) { "Image dimensions exceed QA limit" }
                    val bitmap = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)) { "Clipboard is not a decodable image" }
                    image.setImageBitmap(bitmap)
                    receipt("pasted", bytes)
                }.onFailure { status.text = "Paste failed: ${it.message}" }
            }
        }
        root.addView(status)
        root.addView(copy)
        root.addView(paste)
        root.addView(image, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
    }

    companion object { private const val MAX_IMAGE_BYTES = 16 * 1024 * 1024 }
}
