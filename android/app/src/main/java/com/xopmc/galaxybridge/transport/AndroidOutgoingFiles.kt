package com.xopmc.galaxybridge.transport

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.TransferAck
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

internal data class OutgoingFilesState(val transfers: List<OutgoingFileProgress> = emptyList(), val storageError: Boolean = false)
internal data class FileSendPreview(val uri: Uri, val owner: String, val name: String, val mime: String, val size: Long?)

/** Process owner; activities only enqueue explicit user selections. Play never attaches a sender. */
internal class AndroidOutgoingFiles private constructor(private val context: Context) {
    private val preferences = context.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "GB-file-sender").apply { isDaemon = true } }
    private val watchdog = Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "GB-file-watchdog").apply { isDaemon = true } }
    private val mutableState = MutableStateFlow(OutgoingFilesState())
    val state = mutableState.asStateFlow()
    private val cancellationFences = ConcurrentHashMap.newKeySet<String>()
    private val store = OutgoingFileStore(File(context.filesDir.canonicalFile, "outgoing-files-v1")) { directory ->
        val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try {
            check(OsConstants.S_ISDIR(Os.fstat(fd).st_mode))
            Os.fsync(fd)
        } finally { Os.close(fd) }
    }
    private val sender = OutgoingFileSender(store, ::currentOwner, { records, rejected ->
        mutableState.value = OutgoingFilesState(records, rejected)
        val waiting = records.filter { it.waiting }.mapTo(mutableSetOf()) { it.record.id }
        activeLease?.deadlines?.keys?.removeAll { it !in waiting }
    }, cancellationFences::contains)
    @Volatile private var activeLease: Lease? = null
    private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key in setOf("paired_host_id", "paired_mac_key", "paired_at")) {
            activeLease?.closeIfOwnerChanged(currentOwner())
            refresh()
        }
    }

    init {
        preferences.registerOnSharedPreferenceChangeListener(preferenceListener)
        submit {
            store.list().records.filter { it.phase == OutgoingFilePhase.PREPARED }.forEach {
                store.transition(it.id, it.owner, OutgoingFilePhase.CANCELLED)
            }
        }
        refresh()
        watchdog.scheduleWithFixedDelay({
            activeLease?.let { lease ->
                if (lease.deadlines.values.any { System.nanoTime() >= it }) {
                    submit { sender.timeout(lease.id) }
                    lease.close()
                }
            }
        }, 1, 1, TimeUnit.SECONDS)
    }

    fun currentOwner(): String? {
        if (!enabled) return null
        val host = preferences.getString("paired_host_id", null) ?: return null
        val key = preferences.getString("paired_mac_key", null) ?: return null
        val pairedAt = preferences.getLong("paired_at", 0)
        if (host.isBlank() || key.isBlank() || pairedAt <= 0) return null
        // Same owner namespace as the authenticated receiver; never derived from a wire manifest.
        return MessageDigest.getInstance("SHA-256")
            .digest("downloads-v1\u0000$host\u0000$key\u0000$pairedAt".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    suspend fun preview(uri: Uri): FileSendPreview = withContext(Dispatchers.IO) {
        require(uri.scheme == "content")
        val owner = currentOwner() ?: error("pairing_required")
        var name: String? = null
        var size: Long? = null
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
            }
        }
        val actualName = name ?: error("invalid_filename")
        require(OutgoingFileStore.validName(actualName) && (size == null || size in 0..OutgoingFileStore.MAX_SIZE))
        FileSendPreview(uri, owner, actualName, context.contentResolver.getType(uri) ?: "application/octet-stream", size)
    }

    suspend fun prepare(preview: FileSendPreview): String {
        val prepared = AtomicReference<OutgoingFileRecord?>()
        try {
            return withContext(Dispatchers.IO) {
                val operation = currentCoroutineContext()
                check(currentOwner() == preview.owner) { "pairing_changed" }
                val record = store.prepare(preview.owner, preview.name, preview.mime,
                    { context.contentResolver.openInputStream(preview.uri) ?: error("file_unavailable") },
                    { !operation.isActive || currentOwner() != preview.owner }, OutgoingFilePhase.PREPARED)
                prepared.set(record)
                check(currentOwner() == preview.owner) { "pairing_changed" }
                record.id
            }
        } catch (error: Exception) {
            withContext(NonCancellable + Dispatchers.IO) {
                prepared.get()?.let { record -> store.transition(record.id, record.owner, OutgoingFilePhase.CANCELLED) }
            }
            refresh()
            throw error
        }
    }

    /** The activity keeps Preparing visible until the admission record is durable. */
    suspend fun enqueuePrepared(id: String, owner: String) = withContext(Dispatchers.IO) {
        val record = store.load(id) ?: error("transfer_missing")
        check(record.owner == owner)
        check(record.phase == OutgoingFilePhase.PREPARED)
        val admitted = store.transition(id, owner,
            if (currentOwner() == owner && currentCoroutineContext().isActive) OutgoingFilePhase.QUEUED else OutgoingFilePhase.CANCELLED)
        check(admitted.phase == OutgoingFilePhase.QUEUED) { "pairing_changed" }
        refresh()
    }

    fun refresh() = submit {
        val owner = currentOwner()
        // Revocation/re-pairing discards only private sender snapshots, never selected originals.
        store.list().records.filter { it.owner != owner && !it.terminal }.forEach {
            store.transition(it.id, it.owner, OutgoingFilePhase.CANCELLED)
        }
        sender.refresh()
    }
    fun cancel(id: String, owner: String) {
        cancellationFences.add(id)
        submit {
            sender.cancel(id, owner)
            cancellationFences.remove(id)
        }
    }
    fun retry(id: String, owner: String) = submit { sender.retry(id, owner) }

    fun attach(owner: String, sessionID: String, deviceID: String,
               write: (Envelope) -> Unit, closeTransport: () -> Unit): Lease? {
        if (!enabled || owner != currentOwner()) return null
        val lease = Lease(owner, closeTransport)
        submit {
            if (owner != currentOwner() || lease.closed.get()) return@submit
            activeLease?.close()
            activeLease = lease
            val messageID = AtomicLong(1_000)
            sender.attach(OutgoingFileSender.Connection(lease.id, owner) { builder ->
                check(owner == currentOwner() && !lease.closed.get()) { "transfer_owner_mismatch" }
                val transferID = when (builder.payloadCase) {
                    Envelope.PayloadCase.TRANSFER_MANIFEST -> builder.transferManifest.transferId
                    Envelope.PayloadCase.TRANSFER_CHUNK -> builder.transferChunk.transferId
                    Envelope.PayloadCase.TRANSFER_CANCEL -> builder.transferCancel.transferId
                    else -> error("invalid_file_payload")
                }
                // The watchdog can close a blocked write without waiting for the IO executor.
                lease.deadlines[transferID] = System.nanoTime() + TimeUnit.SECONDS.toNanos(120)
                try {
                    write(builder.setProtocolMajor(1).setProtocolMinor(0).setDeviceId(deviceID)
                        .setSessionId(sessionID).setMessageId(messageID.getAndIncrement()).build())
                } catch (error: Exception) {
                    lease.close()
                    throw OutgoingFileTransportFailure(error)
                }
            })
        }
        return lease
    }

    inner class Lease internal constructor(val owner: String, private val closeTransport: () -> Unit) {
        val id: UUID = UUID.randomUUID()
        val closed = AtomicBoolean(false)
        val deadlines = ConcurrentHashMap<String, Long>()
        private val admittedAcks = AtomicInteger()
        fun acknowledge(ack: TransferAck) {
            if (closed.get()) return
            if (ack.serializedSize > 8192 || !OutgoingFileStore.validID(ack.transferId)) { close(); return }
            if (admittedAcks.incrementAndGet() > 32) { admittedAcks.decrementAndGet(); close(); return }
            submit {
                try { if (!closed.get()) sender.acknowledge(id, ack) }
                finally { admittedAcks.decrementAndGet() }
            }
        }
        fun detach() {
            closed.set(true); deadlines.clear()
            submit {
                sender.detach(id)
                if (activeLease === this) activeLease = null
            }
        }
        fun close() { if (closed.compareAndSet(false, true)) runCatching(closeTransport) }
        fun closeIfOwnerChanged(current: String?) { if (owner != current) close() }
    }
    private fun submit(operation: () -> Unit) {
        executor.execute {
            try { operation() } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(storageError = true)
            }
        }
    }
    companion object {
        val enabled: Boolean get() = FileSendPolicy.enabled(BuildConfig.DISTRIBUTION)
        @Volatile private var instance: AndroidOutgoingFiles? = null
        fun get(context: Context): AndroidOutgoingFiles = instance ?: synchronized(this) {
            instance ?: AndroidOutgoingFiles(context.applicationContext).also { instance = it }
        }
    }
}
