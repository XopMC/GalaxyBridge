package com.xopmc.galaxybridge.service

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

class ForegroundClipboardMonitor(
    context: Context,
    private val outboundHub: ClipboardOutboundHub = ClipboardBridge.outboundHub,
    private val tracker: ClipboardChangeTracker = ClipboardBridge.changeTracker,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor(),
) : AutoCloseable {
    private val appContext = context.applicationContext
    private val clipboard = appContext.getSystemService(ClipboardManager::class.java)
    private val gate = ForegroundClipboardGate()
    private val listener = ClipboardManager.OnPrimaryClipChangedListener(::sample)
    @Volatile private var active = false
    private var imageTask: Future<*>? = null

    fun onStarted() = apply(gate.onStarted())

    fun onStopped() = apply(gate.onStopped())

    fun onWindowFocusChanged(hasFocus: Boolean) = apply(gate.onWindowFocusChanged(hasFocus))

    private fun apply(transition: ClipboardMonitorTransition) {
        when (transition) {
            ClipboardMonitorTransition.NONE -> Unit
            ClipboardMonitorTransition.ACTIVATE_AND_SAMPLE -> {
                active = true
                clipboard.addPrimaryClipChangedListener(listener)
                sample()
            }
            ClipboardMonitorTransition.DEACTIVATE -> {
                active = false
                imageTask?.cancel(true)
                imageTask = null
                clipboard.removePrimaryClipChangedListener(listener)
            }
        }
    }

    private fun sample() {
        if (!active) return
        val description = clipboard.primaryClipDescription ?: return
        if (description.isSensitive()) return
        val generation = description.timestamp.takeIf { it > 0L }
        val clip = clipboard.primaryClip ?: return
        if (clip.itemCount != 1) return
        val item = clip.getItemAt(0)

        if (description.hasMimeType("image/*")) {
            val uri = item.uri?.takeIf { it.scheme == ContentResolver.SCHEME_CONTENT } ?: return
            val mimeType = (0 until description.mimeTypeCount)
                .map(description::getMimeType)
                .firstOrNull { it.startsWith("image/") }
                ?: appContext.contentResolver.getType(uri)
            imageTask?.cancel(true)
            imageTask = executor.submit {
                val png = ClipboardImageCodec.readAsBoundedPng(appContext.contentResolver, uri, mimeType) ?: return@submit
                if (!active || Thread.currentThread().isInterrupted) return@submit
                ClipboardPayloadPolicy.png(
                    png,
                    sensitive = false,
                    tracker = tracker,
                    generation = generation,
                )?.let(outboundHub::publish)
            }
            return
        }

        if (!description.hasMimeType("text/plain") && !description.hasMimeType("text/uri-list")) return
        val text = item.text ?: item.uri?.takeIf { description.hasMimeType("text/uri-list") }?.toString() ?: return
        ClipboardPayloadPolicy.text(
            text,
            sensitive = false,
            tracker = tracker,
            generation = generation,
        )?.let(outboundHub::publish)
    }

    override fun close() {
        if (active) {
            active = false
            clipboard.removePrimaryClipChangedListener(listener)
        }
        imageTask?.cancel(true)
        executor.shutdownNow()
    }

    private fun ClipDescription.isSensitive(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false) == true
}

object ClipboardImageCodec {
    private const val MAX_SOURCE_BYTES = ClipboardPayloadPolicy.MAX_IMAGE_BYTES

    fun readAsBoundedPng(
        resolver: ContentResolver,
        uri: Uri,
        declaredMimeType: String?,
    ): ByteArray? {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT || declaredMimeType?.startsWith("image/") != true) return null
        val knownLength = runCatching { resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull()
        if (knownLength != null && knownLength > MAX_SOURCE_BYTES) return null
        val encoded = runCatching {
            resolver.openInputStream(uri)?.use { it.readBounded(MAX_SOURCE_BYTES) }
        }.getOrNull() ?: return null
        val bounds = decodeBounds(encoded) ?: return null
        if (!ImageDecodeBudget.isPlausible(bounds.first, bounds.second)) return null

        if (bounds.third == "image/png") return encoded
        val sampleSize = ImageDecodeBudget.sampleSize(bounds.first, bounds.second)
        if (sampleSize == Int.MAX_VALUE) return null
        val bitmap = try {
            BitmapFactory.decodeByteArray(
                encoded,
                0,
                encoded.size,
                BitmapFactory.Options().apply { inSampleSize = sampleSize },
            )
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: RuntimeException) {
            null
        } ?: return null
        return try {
            BoundedByteArrayOutputStream(ClipboardPayloadPolicy.MAX_IMAGE_BYTES).use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) null else output.toByteArray()
            }
        } catch (_: IOException) {
            null
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: RuntimeException) {
            null
        } finally {
            bitmap.recycle()
        }
    }

    fun isSafePng(content: ByteArray): Boolean {
        if (content.isEmpty() || content.size > ClipboardPayloadPolicy.MAX_IMAGE_BYTES) return false
        val bounds = decodeBounds(content) ?: return false
        return bounds.third == "image/png" && ImageDecodeBudget.isPlausible(bounds.first, bounds.second)
    }

    fun decodePreview(content: ByteArray, maxPixels: Long = 320L * 320L): Bitmap? {
        val bounds = decodeBounds(content) ?: return null
        if (!ImageDecodeBudget.isPlausible(bounds.first, bounds.second)) return null
        var sample = 1
        while ((bounds.first.toLong() / sample) * (bounds.second.toLong() / sample) > maxPixels) sample *= 2
        return try {
            BitmapFactory.decodeByteArray(
                content,
                0,
                content.size,
                BitmapFactory.Options().apply { inSampleSize = sample },
            )
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun decodeBounds(content: ByteArray): Triple<Int, Int, String?>? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            BitmapFactory.decodeByteArray(content, 0, content.size, options)
        } catch (_: OutOfMemoryError) {
            return null
        } catch (_: RuntimeException) {
            return null
        }
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        return Triple(options.outWidth, options.outHeight, options.outMimeType)
    }

    private fun InputStream.readBounded(limit: Int): ByteArray? {
        val output = ByteArrayOutputStream(minOf(limit, 64 * 1024))
        val buffer = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            if (Thread.currentThread().isInterrupted) return null
            val count = read(buffer)
            if (count < 0) break
            total += count
            if (total > limit) return null
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private class BoundedByteArrayOutputStream(private val limit: Int) : OutputStream() {
        private val delegate = ByteArrayOutputStream(minOf(limit, 64 * 1024))

        override fun write(value: Int) {
            ensureCapacity(1)
            delegate.write(value)
        }

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            ensureCapacity(length)
            delegate.write(buffer, offset, length)
        }

        fun toByteArray(): ByteArray = delegate.toByteArray()

        override fun close() = delegate.close()

        private fun ensureCapacity(additional: Int) {
            if (delegate.size().toLong() + additional > limit) throw IOException("encoded image exceeds limit")
        }
    }
}
