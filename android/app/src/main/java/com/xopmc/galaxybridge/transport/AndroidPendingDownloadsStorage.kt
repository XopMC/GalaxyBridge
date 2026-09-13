package com.xopmc.galaxybridge.transport

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.system.Os
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest

/**
 * MediaStore publication relies on the system provider's scoped-storage collision policy.
 * It is not a promise of renameat2(RENAME_NOREPLACE) against a privileged shell adversary.
 * IS_PENDING keeps partially received bytes unavailable to other ordinary apps.
 */
internal data class DownloadAllocationDiagnostic(
    val stage: String,
    val exceptionType: String? = null,
    val rowFound: Boolean? = null,
    val ownerMatches: Boolean? = null,
    val pathMatches: Boolean? = null,
    val pending: Boolean? = null,
)

internal class AndroidPendingDownloadsStorage(
    context: Context,
    private val allocationDiagnostic: ((DownloadAllocationDiagnostic) -> Unit)? = null,
) : PendingDownloadStorage {
    private val resolver = context.contentResolver
    private val packageName = context.packageName
    private val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

    override fun allocate(name: String, mimeType: String): PendingDownload? {
        var stage = "insert"
        return runCatching {
            val uri = resolver.insert(collection, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType.ifBlank { "application/octet-stream" })
                put(MediaStore.MediaColumns.RELATIVE_PATH, DIRECTORY)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }) ?: run {
                emitAllocationDiagnostic(DownloadAllocationDiagnostic("insert_returned_null"))
                return@runCatching null
            }
            emitAllocationDiagnostic(DownloadAllocationDiagnostic("insert_returned_uri"))
            var accepted = false
            try {
                // insert creates a MediaStore row; the backing file may not exist
                // until its first writable open. Materialize before read-only
                // identity inspection (observed ENOENT on Samsung's provider).
                stage = "materialize"
                requireNotNull(resolver.openFileDescriptor(uri, "rw")).use { descriptor ->
                    Os.fsync(descriptor.fileDescriptor)
                }
                stage = "inspect"
                inspect(uri, diagnoseAllocation = true)?.takeIf { it.pending }.also { accepted = it != null }
            } finally {
                if (!accepted) {
                    // Only the exact row created by this call, and only while
                    // pending. Never delete a published or pre-existing item.
                    runCatching { resolver.delete(uri, "${MediaStore.MediaColumns.IS_PENDING}=1", null) }
                }
            }
        }.onFailure {
            emitAllocationDiagnostic(DownloadAllocationDiagnostic(stage, exceptionType = it.javaClass.simpleName))
        }.getOrNull()
    }

    // An optional QA observer must never change storage behavior or disclose content/paths.
    private fun emitAllocationDiagnostic(event: DownloadAllocationDiagnostic) {
        runCatching { allocationDiagnostic?.invoke(event) }
    }

    override fun resolve(item: PendingDownload): PendingDownload? = runCatching {
        inspect(validUri(item.id))?.takeIf { it.identity == item.identity }
    }.getOrNull()

    private fun validUri(value: String): Uri {
        val uri = Uri.parse(value)
        require(uri.scheme == "content" && uri.authority == "media" &&
            uri.pathSegments.size == 3 && uri.pathSegments[0] == MediaStore.VOLUME_EXTERNAL_PRIMARY &&
            uri.pathSegments[1] == "downloads" && ContentUris.parseId(uri) > 0)
        return uri
    }

    private fun inspect(uri: Uri, diagnoseAllocation: Boolean = false): PendingDownload? {
        var stage = "inspect_query"
        fun emit(event: DownloadAllocationDiagnostic) {
            if (diagnoseAllocation) emitAllocationDiagnostic(event)
        }
        val columns = arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.IS_PENDING,
            MediaStore.MediaColumns.OWNER_PACKAGE_NAME, MediaStore.MediaColumns.RELATIVE_PATH)
        try {
            val cursor = resolver.query(uri, columns, null, null, null) ?: run {
                emit(DownloadAllocationDiagnostic(stage, rowFound = false))
                return null
            }
            return cursor.use {
                if (!it.moveToFirst()) {
                    emit(DownloadAllocationDiagnostic(stage, rowFound = false))
                    return@use null
                }
                val ownerMatches = it.getString(2) == packageName
                val pathMatches = it.getString(3) == DIRECTORY
                emit(DownloadAllocationDiagnostic("inspect_metadata", rowFound = true,
                    ownerMatches = ownerMatches, pathMatches = pathMatches, pending = it.getInt(1) == 1))
                if (!ownerMatches || !pathMatches) return@use null
                stage = "inspect_read_open"
                val descriptor = resolver.openFileDescriptor(uri, "r") ?: run {
                    emit(DownloadAllocationDiagnostic("inspect_read_open_returned_null"))
                    return@use null
                }
                descriptor.use { opened ->
                    stage = "inspect_stat"
                    val stat = Os.fstat(opened.fileDescriptor)
                    emit(DownloadAllocationDiagnostic("inspect_complete"))
                    PendingDownload(uri.toString(), "${stat.st_dev}:${stat.st_ino}", it.getString(0), it.getInt(1) == 1)
                }
            }
        } catch (error: Exception) {
            emit(DownloadAllocationDiagnostic(stage, exceptionType = error.javaClass.simpleName))
            throw error
        }
    }

    private fun <T> channel(item: PendingDownload, write: Boolean, block: (FileChannel) -> T): T? = runCatching {
        val current = resolve(item) ?: return@runCatching null
        if (write && !current.pending) return@runCatching null
        resolver.openFileDescriptor(validUri(item.id), if (write) "rw" else "r")?.use { descriptor ->
            val stat = Os.fstat(descriptor.fileDescriptor)
            if ("${stat.st_dev}:${stat.st_ino}" != item.identity) return@use null
            // dup gives the stream an independently owned descriptor, avoiding double-close reuse.
            val duplicate = ParcelFileDescriptor.dup(descriptor.fileDescriptor)
            if (write) ParcelFileDescriptor.AutoCloseOutputStream(duplicate).use { block(it.channel) }
            else ParcelFileDescriptor.AutoCloseInputStream(duplicate).use { block(it.channel) }
        }
    }.getOrNull()

    override fun length(item: PendingDownload): Long? = channel(item, false) { it.size() }
    override fun truncate(item: PendingDownload, length: Long): Boolean = channel(item, true) {
        require(length >= 0 && length <= it.size())
        it.truncate(length); it.force(true); it.size() == length
    } ?: false
    override fun write(item: PendingDownload, offset: Long, bytes: ByteArray): Boolean = channel(item, true) {
        if (it.size() != offset) return@channel false
        it.position(offset)
        val buffer = ByteBuffer.wrap(bytes)
        while (buffer.hasRemaining()) if (it.write(buffer) <= 0) return@channel false
        it.force(true)
        it.size() == checkedAddOffset(offset, bytes.size)
    } ?: false
    override fun hashPrefix(item: PendingDownload, length: Long, digest: MessageDigest): Boolean = channel(item, false) {
        val buffer = ByteBuffer.allocate(64 * 1024)
        var remaining = length
        while (remaining > 0) {
            buffer.clear(); buffer.limit(minOf(buffer.capacity().toLong(), remaining).toInt())
            val count = it.read(buffer)
            if (count <= 0) return@channel false
            digest.update(buffer.array(), 0, count)
            remaining -= count
        }
        true
    } ?: false
    override fun matches(item: PendingDownload, offset: Long, bytes: ByteArray): Boolean = channel(item, false) {
        it.position(offset)
        val buffer = ByteBuffer.allocate(minOf(bytes.size, 64 * 1024))
        var matched = 0
        while (matched < bytes.size) {
            buffer.clear(); buffer.limit(minOf(buffer.capacity(), bytes.size - matched))
            val count = it.read(buffer)
            if (count <= 0) return@channel false
            repeat(count) { index -> if (buffer.array()[index] != bytes[matched + index]) return@channel false }
            matched += count
        }
        true
    } ?: false
    override fun publish(item: PendingDownload): PendingDownload? = runCatching {
        val current = resolve(item)?.takeIf { it.pending } ?: return@runCatching null
        if (resolver.update(validUri(current.id), ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, "${MediaStore.MediaColumns.IS_PENDING}=1", null) != 1) return@runCatching null
        resolve(item)?.takeIf { !it.pending }
    }.getOrNull()
    override fun deletePending(item: PendingDownload): Boolean = runCatching {
        val current = resolve(item) ?: return@runCatching false
        current.pending && resolver.delete(validUri(item.id), "${MediaStore.MediaColumns.IS_PENDING}=1", null) == 1
    }.getOrDefault(false)

    override fun isAbsent(item: PendingDownload): Boolean = runCatching {
        resolver.query(validUri(item.id), arrayOf(MediaStore.MediaColumns._ID), null, null, null)
            ?.use { !it.moveToFirst() } ?: false
    }.getOrDefault(false)

    private companion object { const val DIRECTORY = "Download/GalaxyBridge/" }
}

/** SQLite FULL synchronous transactions: a failed commit never advances an in-memory preference. */
internal class SQLiteDownloadJournal(context: Context) : SQLiteOpenHelper(context, "downloads-checkpoints.db", null, 2), DownloadJournal {
    override fun onConfigure(db: SQLiteDatabase) {
        db.execSQL("PRAGMA synchronous=FULL")
        // Bound metadata by disk bytes, not a customer's lifetime send count. Existing
        // completion IDs remain durable; quota/disk failure is explicit and never evicts them.
        val pageSize = db.rawQuery("PRAGMA page_size", null).use { it.moveToFirst(); it.getLong(0) }
        db.rawQuery("PRAGMA max_page_count=${256L * 1024 * 1024 / pageSize}", null).use { it.moveToFirst() }
    }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE transfers (id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, mime TEXT NOT NULL, sha BLOB NOT NULL, uri TEXT NOT NULL, identity TEXT NOT NULL, item_name TEXT NOT NULL, pending INTEGER NOT NULL, offset INTEGER NOT NULL, prefix BLOB NOT NULL, phase TEXT NOT NULL, updated INTEGER NOT NULL)")
        db.execSQL("CREATE INDEX transfers_pending ON transfers(phase, pending)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion == 1 && newVersion == 2) { "unsupported_checkpoint_version" }
        db.execSQL("CREATE INDEX IF NOT EXISTS transfers_pending ON transfers(phase, pending)")
    }
    @Synchronized override fun store(record: DownloadCheckpoint): Boolean = runCatching {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val m = record.manifest
            db.delete("transfers", "id=?", arrayOf(m.transferId))
            db.insertOrThrow("transfers", null, ContentValues().apply {
                put("id", m.transferId); put("owner", record.owner); put("name", m.relativeName); put("size", m.size)
                put("mime", m.mimeType); put("sha", m.sha256); put("uri", record.item.id); put("identity", record.item.identity)
                put("item_name", record.item.name); put("pending", if (record.item.pending) 1 else 0)
                put("offset", record.offset); put("prefix", record.prefix); put("phase", record.phase.name); put("updated", record.updatedAt)
            })
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        true
    }.getOrDefault(false)
    @Synchronized override fun load(id: String): DownloadCheckpoint? = read("id=?", arrayOf(id)).singleOrNull()
    @Synchronized override fun all(): List<DownloadCheckpoint> = read(null, null)
    @Synchronized override fun unsettled(): List<DownloadCheckpoint> = read(UNSETTLED, null)
    @Synchronized override fun activeCount(): Long = readableDatabase.rawQuery(
        "SELECT COUNT(*) FROM transfers WHERE $UNSETTLED", null,
    ).use { it.moveToFirst(); it.getLong(0) }
    private fun read(where: String?, args: Array<String>?): List<DownloadCheckpoint> = readableDatabase.query(
        "transfers", null, where, args, null, null, null,
    ).use { c ->
        buildList {
            while (c.moveToNext()) {
                fun text(name: String) = c.getString(c.getColumnIndexOrThrow(name))
                fun long(name: String) = c.getLong(c.getColumnIndexOrThrow(name))
                fun blob(name: String) = c.getBlob(c.getColumnIndexOrThrow(name))
                val manifest = SafIncomingManifest(text("id"), text("name"), long("size"), text("mime"), blob("sha"))
                val offset = long("offset"); val prefix = blob("prefix")
                check(manifest.size in 0..ResumableDownloadsTransfer.MAX_SIZE && offset in 0..manifest.size && prefix.size == 32 && manifest.sha256.size == 32)
                add(DownloadCheckpoint(text("owner"), manifest,
                    PendingDownload(text("uri"), text("identity"), text("item_name"), long("pending") == 1L),
                    offset, prefix, DownloadPhase.valueOf(text("phase")), long("updated")))
            }
        }
    }
    private companion object {
        const val UNSETTLED = "phase IN ('RECEIVING','VERIFIED') OR (phase='CANCELLED' AND pending=1)"
    }

}
