package com.xopmc.galaxybridge.service

import com.xopmc.galaxybridge.protocol.v1.ClipboardKind
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

data class ClipboardPayload(
    val kind: ClipboardKind,
    val content: ByteArray,
    val changeId: String,
)

enum class ClipboardOutboundResult {
    SENT,
    NO_CONNECTED_MAC,
    QUEUE_FULL,
}

class ClipboardOutboundHub(private val capacity: Int = DEFAULT_CAPACITY) {
    init {
        require(capacity > 0)
    }

    private val nextSubscriptionId = AtomicLong()
    private val subscriptions = linkedMapOf<Long, Channel<ClipboardPayload>>()

    fun subscribe(): Subscription {
        val id = nextSubscriptionId.incrementAndGet()
        val channel = Channel<ClipboardPayload>(capacity)
        synchronized(subscriptions) {
            subscriptions[id] = channel
        }
        return Subscription(channel.receiveAsFlow()) {
            synchronized(subscriptions) {
                subscriptions.remove(id)?.close()
            }
        }
    }

    /**
     * SENT means at least one live Mac event channel accepted the item. A stale/full parallel
     * channel cannot turn a successful delivery to another connected channel into a false error.
     */
    fun publish(payload: ClipboardPayload): ClipboardOutboundResult = synchronized(subscriptions) {
        if (subscriptions.isEmpty()) return ClipboardOutboundResult.NO_CONNECTED_MAC

        var delivered = false
        val closed = mutableListOf<Long>()
        subscriptions.forEach { (id, channel) ->
            val result = channel.trySend(payload)
            delivered = delivered || result.isSuccess
            if (result.isClosed) closed += id
        }
        closed.forEach { subscriptions.remove(it) }
        when {
            delivered -> ClipboardOutboundResult.SENT
            subscriptions.isEmpty() -> ClipboardOutboundResult.NO_CONNECTED_MAC
            else -> ClipboardOutboundResult.QUEUE_FULL
        }
    }

    class Subscription internal constructor(
        val events: Flow<ClipboardPayload>,
        private val closeAction: () -> Unit,
    ) : AutoCloseable {
        override fun close() = closeAction()
    }

    private companion object {
        const val DEFAULT_CAPACITY = 32
    }
}

object ClipboardFingerprint {
    fun digest(kind: ClipboardKind, content: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(kind.number.toByte())
        digest.update(0)
        digest.update(content)
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }
}

class ClipboardEchoSuppressor(private val capacity: Int = DEFAULT_CAPACITY) {
    init {
        require(capacity > 0)
    }

    private val inboundDigests = linkedSetOf<String>()

    fun markInbound(kind: ClipboardKind, content: ByteArray) {
        val digest = ClipboardFingerprint.digest(kind, content)
        synchronized(inboundDigests) {
            inboundDigests.remove(digest)
            inboundDigests.add(digest)
            while (inboundDigests.size > capacity) {
                inboundDigests.remove(inboundDigests.first())
            }
        }
    }

    fun consume(kind: ClipboardKind, content: ByteArray): Boolean {
        val digest = ClipboardFingerprint.digest(kind, content)
        return synchronized(inboundDigests) { inboundDigests.remove(digest) }
    }

    private companion object {
        const val DEFAULT_CAPACITY = 64
    }
}

class ClipboardChangeTracker(
    private val echoSuppressor: ClipboardEchoSuppressor,
    private val duplicateWindowMillis: Long = DEFAULT_DUPLICATE_WINDOW_MILLIS,
    private val clockMillis: () -> Long = System::currentTimeMillis,
) {
    private var lastDigest: String? = null
    private var lastObservedAtMillis: Long = Long.MIN_VALUE
    private var lastGeneration: Long? = null

    init {
        require(duplicateWindowMillis >= 0)
    }

    @Synchronized
    fun prepare(kind: ClipboardKind, content: ByteArray, generation: Long? = null): ClipboardPayload? {
        val digest = ClipboardFingerprint.digest(kind, content)
        val now = clockMillis()
        val sameObservedClipboard = generation != null && generation == lastGeneration
        val recentContentDuplicate = generation == null && elapsedSinceLast(now) <= duplicateWindowMillis
        if (digest == lastDigest && (sameObservedClipboard || recentContentDuplicate)) return null
        if (echoSuppressor.consume(kind, content)) {
            lastDigest = digest
            lastObservedAtMillis = now
            lastGeneration = generation
            return null
        }
        lastDigest = digest
        lastObservedAtMillis = now
        lastGeneration = generation
        return ClipboardPayload(
            kind = kind,
            content = content,
            changeId = ClipboardOccurrenceIdentity.next(digest),
        )
    }

    /**
     * An explicit remote Copy/Cut command is a new user gesture even when the
     * selected value is identical to a clip that just arrived from the Mac.
     * Consume the pending echo marker, but never suppress the explicit action.
     */
    @Synchronized
    fun prepareExplicit(kind: ClipboardKind, content: ByteArray, generation: Long): ClipboardPayload {
        val digest = ClipboardFingerprint.digest(kind, content)
        echoSuppressor.consume(kind, content)
        lastDigest = digest
        lastObservedAtMillis = clockMillis()
        lastGeneration = generation
        return ClipboardPayload(
            kind = kind,
            content = content,
            changeId = ClipboardOccurrenceIdentity.next(digest),
        )
    }

    private fun elapsedSinceLast(now: Long): Long =
        if (lastObservedAtMillis == Long.MIN_VALUE || now < lastObservedAtMillis) Long.MAX_VALUE else now - lastObservedAtMillis

    private companion object {
        const val DEFAULT_DUPLICATE_WINDOW_MILLIS = 2_000L
    }
}

private object ClipboardOccurrenceIdentity {
    private val processSession = UUID.randomUUID().toString()
    private val sequence = AtomicLong()

    fun next(contentDigest: String): String =
        "$processSession:${sequence.incrementAndGet()}:$contentDigest"
}

object ClipboardPayloadPolicy {
    const val MAX_TEXT_CHARACTERS = 256 * 1024
    const val MAX_TEXT_BYTES = 256 * 1024
    const val MAX_IMAGE_BYTES = 4 * 1024 * 1024

    fun text(
        value: CharSequence,
        sensitive: Boolean,
        tracker: ClipboardChangeTracker,
        generation: Long? = null,
    ): ClipboardPayload? {
        if (sensitive || value.length > MAX_TEXT_CHARACTERS) return null
        val text = value.toString()
        val content = text.encodeToByteArray()
        if (content.isEmpty() || content.size > MAX_TEXT_BYTES) return null
        val kind = if (isWebUrl(text)) {
            ClipboardKind.CLIPBOARD_KIND_URL
        } else {
            ClipboardKind.CLIPBOARD_KIND_TEXT
        }
        return tracker.prepare(kind, content, generation)
    }

    fun png(
        content: ByteArray,
        sensitive: Boolean,
        tracker: ClipboardChangeTracker,
        generation: Long? = null,
    ): ClipboardPayload? {
        if (sensitive || content.isEmpty() || content.size > MAX_IMAGE_BYTES) return null
        return tracker.prepare(ClipboardKind.CLIPBOARD_KIND_PNG, content, generation)
    }

    private fun isWebUrl(value: String): Boolean = runCatching {
        val uri = URI(value.trim())
        uri.scheme?.lowercase() in setOf("http", "https") && !uri.rawAuthority.isNullOrBlank()
    }.getOrDefault(false)
}

/**
 * Builds the clipboard payload for an explicit Copy/Cut command handled by
 * Accessibility. This reads only the selected range of the focused editable
 * node; it never samples the global Android clipboard and never exposes
 * password fields.
 */
object AccessibilitySelectionClipboard {
    fun shouldPublish(
        isCopy: Boolean,
        actionHandled: Boolean,
        payloadAvailable: Boolean,
    ): Boolean = payloadAvailable && (isCopy || actionHandled)

    fun payload(
        text: CharSequence?,
        selectionStart: Int,
        selectionEnd: Int,
        isPassword: Boolean,
        generation: Long,
        tracker: ClipboardChangeTracker,
    ): ClipboardPayload? {
        if (isPassword || text == null) return null
        val value = text.toString()
        if (selectionStart < 0 || selectionEnd <= selectionStart || selectionEnd > value.length) return null
        val selection = value.substring(selectionStart, selectionEnd)
        if (selection.length > ClipboardPayloadPolicy.MAX_TEXT_CHARACTERS) return null
        val content = selection.encodeToByteArray()
        if (content.isEmpty() || content.size > ClipboardPayloadPolicy.MAX_TEXT_BYTES) return null
        val kind = if (runCatching {
                val uri = URI(selection.trim())
                uri.scheme?.lowercase() in setOf("http", "https") && !uri.rawAuthority.isNullOrBlank()
            }.getOrDefault(false)
        ) {
            ClipboardKind.CLIPBOARD_KIND_URL
        } else {
            ClipboardKind.CLIPBOARD_KIND_TEXT
        }
        return tracker.prepareExplicit(kind, content, generation)
    }
}

enum class SharedContentKind {
    TEXT,
    URL,
    IMAGE,
}

data class SharedContentDescriptor(val kind: SharedContentKind)

object ClipboardSharePolicy {
    const val ACTION_SEND = "android.intent.action.SEND"

    fun text(action: String?, mimeType: String?, value: CharSequence?): SharedContentDescriptor? {
        if (action != ACTION_SEND || mimeType !in setOf("text/plain", "text/uri-list") || value == null) return null
        if (value.isEmpty() || value.length > ClipboardPayloadPolicy.MAX_TEXT_CHARACTERS) return null
        val kind = if (mimeType == "text/uri-list" || isWebUrl(value.toString())) {
            SharedContentKind.URL
        } else {
            SharedContentKind.TEXT
        }
        if (kind == SharedContentKind.URL && !isWebUrl(value.toString())) return null
        return SharedContentDescriptor(kind)
    }

    fun image(action: String?, mimeType: String?, uriScheme: String?): SharedContentDescriptor? {
        if (action != ACTION_SEND || mimeType?.startsWith("image/") != true || uriScheme != "content") return null
        return SharedContentDescriptor(SharedContentKind.IMAGE)
    }

    private fun isWebUrl(value: String): Boolean = runCatching {
        val uri = URI(value.trim())
        uri.scheme?.lowercase() in setOf("http", "https") && !uri.rawAuthority.isNullOrBlank()
    }.getOrDefault(false)
}

object ImageDecodeBudget {
    const val MAX_DECODED_PIXELS = 4_000_000L
    private const val MAX_SOURCE_PIXELS = 100_000_000L
    private const val MAX_SOURCE_EDGE = 16_384

    fun isPlausible(width: Int, height: Int): Boolean {
        if (width <= 0 || height <= 0 || width > MAX_SOURCE_EDGE || height > MAX_SOURCE_EDGE) return false
        return width.toLong() * height.toLong() <= MAX_SOURCE_PIXELS
    }

    fun sampleSize(width: Int, height: Int): Int {
        if (!isPlausible(width, height)) return Int.MAX_VALUE
        var sample = 1
        while ((width.toLong() / sample) * (height.toLong() / sample) > MAX_DECODED_PIXELS) {
            sample *= 2
        }
        return sample
    }
}

enum class ClipboardMonitorTransition {
    NONE,
    ACTIVATE_AND_SAMPLE,
    DEACTIVATE,
}

class ForegroundClipboardGate {
    private var started = false
    private var focused = false
    private var active = false

    fun onStarted(): ClipboardMonitorTransition {
        started = true
        return reconcile()
    }

    fun onStopped(): ClipboardMonitorTransition {
        started = false
        return reconcile()
    }

    fun onWindowFocusChanged(hasFocus: Boolean): ClipboardMonitorTransition {
        focused = hasFocus
        return reconcile()
    }

    private fun reconcile(): ClipboardMonitorTransition {
        val shouldBeActive = started && focused
        if (shouldBeActive == active) return ClipboardMonitorTransition.NONE
        active = shouldBeActive
        return if (active) ClipboardMonitorTransition.ACTIVATE_AND_SAMPLE else ClipboardMonitorTransition.DEACTIVATE
    }
}

object ClipboardBridge {
    val echoSuppressor = ClipboardEchoSuppressor()
    val changeTracker = ClipboardChangeTracker(echoSuppressor)
    val outboundHub = ClipboardOutboundHub()
}
