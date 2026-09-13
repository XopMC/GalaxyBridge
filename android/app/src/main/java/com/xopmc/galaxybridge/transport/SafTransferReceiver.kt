package com.xopmc.galaxybridge.transport

import android.content.ContentResolver
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import com.xopmc.galaxybridge.protocol.v1.TransferAck
import com.xopmc.galaxybridge.protocol.v1.TransferChunk
import com.xopmc.galaxybridge.protocol.v1.TransferManifest
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest

internal class SafTransferReceiver(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(APP_PREFERENCES, Context.MODE_PRIVATE)
    private val legacyTransfer = ResumableSafTransfer(
        storage = AndroidSafTransferStorage(appContext, preferences),
        journal = SharedPreferencesSafTransferJournal(
            appContext.getSharedPreferences(TRANSFER_PREFERENCES, Context.MODE_PRIVATE),
        ),
    )

    // Server restarts may briefly overlap while old sockets retire. Share one mutation
    // coordinator for the process so two receiver instances cannot write the same item.
    private val downloads = synchronized(DOWNLOADS_LOCK) {
        sharedDownloads ?: SQLiteDownloadJournal(appContext).let { journal ->
            Pair(journal, ResumableDownloadsTransfer(AndroidPendingDownloadsStorage(appContext), journal))
                .also { sharedDownloads = it }
        }
    }
    private val downloadsJournal = downloads.first
    private val transfer = downloads.second

    init {
        if (preferences.contains(PAIRED_HOST_ID)) legacyTransfer.cleanup() else revoke()
    }

    /** Capture before authentication and compare afterwards; every FILE operation fences rotation. */
    fun authenticatedOwner(hostId: String): String? {
        if (hostId != preferences.getString(PAIRED_HOST_ID, null)) return null
        val key = preferences.getString("paired_mac_key", null) ?: return null
        val pairedAt = preferences.getLong("paired_at", 0)
        if (pairedAt <= 0) return null
        return MessageDigest.getInstance("SHA-256")
            .digest("downloads-v1\u0000$hostId\u0000$key\u0000$pairedAt".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    fun accept(owner: String?, manifest: TransferManifest): TransferAck {
        if (owner == null || !isCurrentOwner(owner)) return rejected(manifest.transferId)
        return transfer.accept(owner, SafIncomingManifest(manifest.transferId, manifest.relativeName,
            manifest.size, manifest.mimeType, manifest.sha256.toByteArray())).toProtocolAck()
    }

    @Synchronized
    fun append(owner: String?, chunk: TransferChunk): TransferAck {
        if (owner == null || !isCurrentOwner(owner)) return rejected(chunk.transferId)
        return transfer.append(owner, SafIncomingChunk(chunk.transferId, chunk.offset,
            chunk.content.toByteArray())).toProtocolAck()
    }

    @Synchronized
    fun cancel(owner: String?, transferId: String): TransferAck {
        if (owner == null || !isCurrentOwner(owner)) return rejected(transferId)
        return transfer.cancel(owner, transferId).toProtocolAck()
    }

    fun cleanup(nowMillis: Long = System.currentTimeMillis()) {
        legacyTransfer.cleanup(nowMillis)
        // Completed receipts survive cleanup; deleting a final is never a cleanup side effect.
        downloadsJournal.unsettled().filter {
            nowMillis - it.updatedAt > 7L * 24 * 60 * 60 * 1000 }.forEach { transfer.cancel(it.owner, it.manifest.transferId) }
    }

    @Synchronized
    fun revoke() {
        legacyTransfer.revoke()
        downloadsJournal.unsettled().forEach {
            transfer.cancel(it.owner, it.manifest.transferId)
        }
    }

    private fun isCurrentOwner(owner: String): Boolean = preferences.getString(PAIRED_HOST_ID, null)
        ?.let(::authenticatedOwner) == owner

    private fun rejected(id: String): TransferAck = TransferAck.newBuilder().setTransferId(id)
        .setFailureReason("transfer_owner_mismatch").build()

    private fun DownloadReceipt.toProtocolAck(): TransferAck = TransferAck.newBuilder()
        .setTransferId(result.transferId).setConfirmedOffset(result.confirmedOffset)
        .setComplete(result.complete).setFailureReason(result.failureReason)
        .setPublishedName(publishedName.orEmpty()).build()

    private companion object {
        val DOWNLOADS_LOCK = Any()
        var sharedDownloads: Pair<SQLiteDownloadJournal, ResumableDownloadsTransfer>? = null
        const val APP_PREFERENCES = "galaxybridge"
        const val TRANSFER_PREFERENCES = "galaxybridge_saf_transfers"
        const val PAIRED_HOST_ID = "paired_host_id"
    }
}

private class AndroidSafTransferStorage(
    context: Context,
    private val preferences: SharedPreferences,
) : SafTransferStorage {
    private val resolver: ContentResolver = context.contentResolver
    private val appContext = context.applicationContext

    override val selectedTreeId: String?
        get() = preferences.getString(SAF_TREE, null)

    override fun createTemporary(treeId: String, mimeType: String, displayName: String): SafDocument? =
        runCatching {
            DocumentFile.fromTreeUri(appContext, Uri.parse(treeId))
                ?.createFile(mimeType, displayName)
                ?.toSafDocument()
        }.getOrNull()

    override fun resolve(documentId: String): SafDocument? = runCatching {
        DocumentFile.fromSingleUri(appContext, Uri.parse(documentId))
            ?.takeIf(DocumentFile::exists)
            ?.toSafDocument()
    }.getOrNull()

    override fun supportsResumableWrite(document: SafDocument): Boolean =
        withWritableChannel(document) { channel ->
            val length = channel.size()
            channel.position(length)
            channel.truncate(length)
            channel.position() == length && channel.size() == length
        } ?: false

    override fun length(document: SafDocument): Long? =
        withWritableChannel(document) { channel -> channel.size() }

    override fun truncate(document: SafDocument, length: Long): Boolean =
        withWritableChannel(document) { channel ->
            channel.truncate(length)
            channel.force(true)
            channel.size() == length
        } ?: false

    override fun write(document: SafDocument, offset: Long, bytes: ByteArray): Boolean =
        withWritableChannel(document) { channel ->
            if (channel.size() != offset) return@withWritableChannel false
            val expectedLength = checkedAddOffset(offset, bytes.size) ?: return@withWritableChannel false
            channel.position(offset)
            val buffer = ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) {
                if (channel.write(buffer) <= 0) return@withWritableChannel false
            }
            channel.force(true)
            channel.size() == expectedLength
        } ?: false

    override fun updateSha256Prefix(document: SafDocument, length: Long, digest: MessageDigest): Boolean =
        runCatching {
            resolver.openInputStream(Uri.parse(document.id))?.use { input ->
                SafCheckpointHashing.updatePrefix(input, length, digest)
            } ?: false
        }.getOrDefault(false)

    override fun matches(document: SafDocument, offset: Long, bytes: ByteArray): Boolean =
        withReadableChannel(document) { channel ->
            val endOffset = checkedAddOffset(offset, bytes.size) ?: return@withReadableChannel false
            if (channel.size() < endOffset) return@withReadableChannel false
            channel.position(offset)
            val buffer = ByteBuffer.allocate(minOf(HASH_BUFFER_SIZE, bytes.size.coerceAtLeast(1)))
            var compared = 0
            while (compared < bytes.size) {
                buffer.clear()
                buffer.limit(minOf(buffer.capacity(), bytes.size - compared))
                val count = channel.read(buffer)
                if (count <= 0) return@withReadableChannel false
                buffer.flip()
                repeat(count) { index ->
                    if (buffer.get() != bytes[compared + index]) return@withReadableChannel false
                }
                compared += count
            }
            true
        } ?: false

    override fun sha256(document: SafDocument): ByteArray? = runCatching {
        val digest = MessageDigest.getInstance("SHA-256")
        resolver.openInputStream(Uri.parse(document.id))?.use { input ->
            val buffer = ByteArray(HASH_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        } ?: return@runCatching null
        digest.digest()
    }.getOrNull()

    override fun rename(document: SafDocument, displayName: String): SafDocument? = runCatching {
        val renamedUri = DocumentsContract.renameDocument(resolver, Uri.parse(document.id), displayName)
            ?: return@runCatching null
        DocumentFile.fromSingleUri(appContext, renamedUri)?.toSafDocument()
    }.getOrNull()

    override fun delete(document: SafDocument): Boolean = runCatching {
        DocumentsContract.deleteDocument(resolver, Uri.parse(document.id))
    }.getOrDefault(false)

    override fun finalDocumentExists(treeId: String, displayName: String): Boolean = runCatching {
        DocumentFile.fromTreeUri(appContext, Uri.parse(treeId))?.findFile(displayName) != null
    }.getOrDefault(false)

    private fun DocumentFile.toSafDocument(): SafDocument? =
        name?.let { SafDocument(uri.toString(), it) }

    private inline fun <T> withWritableChannel(
        document: SafDocument,
        operation: (java.nio.channels.FileChannel) -> T,
    ): T? = runCatching {
        val descriptor = resolver.openFileDescriptor(Uri.parse(document.id), "rw")
            ?: return@runCatching null
        descriptor.use { parcelFileDescriptor ->
            val duplicated = android.os.ParcelFileDescriptor.dup(parcelFileDescriptor.fileDescriptor)
            try {
                FileOutputStream(duplicated.fileDescriptor).use { output -> operation(output.channel) }
            } finally {
                runCatching { duplicated.close() }
            }
        }
    }.getOrNull()

    private inline fun <T> withReadableChannel(
        document: SafDocument,
        operation: (java.nio.channels.FileChannel) -> T,
    ): T? = runCatching {
        val descriptor = resolver.openFileDescriptor(Uri.parse(document.id), "r")
            ?: return@runCatching null
        descriptor.use { parcelFileDescriptor ->
            val duplicated = android.os.ParcelFileDescriptor.dup(parcelFileDescriptor.fileDescriptor)
            try {
                FileInputStream(duplicated.fileDescriptor).use { input -> operation(input.channel) }
            } finally {
                runCatching { duplicated.close() }
            }
        }
    }.getOrNull()

    private companion object {
        const val SAF_TREE = "saf_tree"
        const val HASH_BUFFER_SIZE = 1024 * 1024
    }
}

private class SharedPreferencesSafTransferJournal(
    private val preferences: SharedPreferences,
) : SafTransferJournal {
    private val failedValues = mutableMapOf<String, String?>()

    @Synchronized
    override fun load(transferId: String): SafTransferRecord? =
        effectiveValue(key(transferId))?.let(::decode)?.takeIf { it.transferId == transferId }

    @Synchronized
    override fun store(record: SafTransferRecord): Boolean {
        val key = key(record.transferId)
        val oldValue = effectiveValue(key)
        if (preferences.edit().putString(key, encode(record)).commit()) {
            failedValues.remove(key)
            return true
        }
        failedValues[key] = oldValue
        restore(key, oldValue)
        return false
    }

    @Synchronized
    override fun remove(transferId: String) {
        val key = key(transferId)
        val oldValue = effectiveValue(key)
        if (preferences.edit().remove(key).commit()) {
            failedValues.remove(key)
        } else {
            failedValues[key] = oldValue
            restore(key, oldValue)
        }
    }

    @Synchronized
    override fun all(): List<SafTransferRecord> {
        val values = preferences.all
            .filterKeys { it.startsWith(RECORD_PREFIX) }
            .mapValuesTo(mutableMapOf()) { it.value as? String }
        failedValues.forEach { (key, value) ->
            if (value == null) values.remove(key) else values[key] = value
        }
        return values.values.mapNotNull { value -> value?.let(::decode) }
    }

    @Synchronized
    override fun contains(transferId: String): Boolean = effectiveValue(key(transferId)) != null

    private fun encode(record: SafTransferRecord): String = SafTransferRecordCodec.encode(record)

    private fun decode(encoded: String): SafTransferRecord? = SafTransferRecordCodec.decode(encoded)

    private fun effectiveValue(key: String): String? =
        if (failedValues.containsKey(key)) failedValues[key] else preferences.getString(key, null)

    private fun restore(key: String, value: String?) {
        val editor = preferences.edit()
        if (value == null) editor.remove(key) else editor.putString(key, value)
        editor.commit()
    }

    private fun key(transferId: String): String = RECORD_PREFIX + MessageDigest.getInstance("SHA-256")
        .digest(transferId.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    private companion object {
        const val RECORD_PREFIX = "transfer."
    }
}
