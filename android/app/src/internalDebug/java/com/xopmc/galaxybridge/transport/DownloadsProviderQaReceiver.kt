package com.xopmc.galaxybridge.transport

import android.content.ContentResolver
import android.content.ContentUris
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.system.Os
import android.util.AtomicFile
import com.xopmc.galaxybridge.BuildConfig
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

/** Shell-only, internalDebug-only integration test. It never instantiates SafTransferReceiver,
 * whose production constructor can revoke/clean paired transfers. All core and provider operations
 * below are real; only SQLite's namespace is redirected to this run's private directory. */
class DownloadsProviderQaReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val runID = intent.getStringExtra("run_id")
        val operation = intent.getStringExtra("operation")
        val validID = runCatching { UUID.fromString(runID).toString() == runID }.getOrDefault(false)
        if (intent.action != ACTION || !BuildConfig.DEBUG || BuildConfig.DISTRIBUTION != "internal" ||
            intent.getStringExtra("confirm_target") != TARGET_SERIAL || !validID ||
            operation !in setOf("prepare", "resume", "cleanup", "diagnose")) {
            resultCode = 2
            resultData = "invalid_qa_request"
            return
        }
        val pending = goAsync()
        // Serialized across receiver instances; no UI, wake lock, settings or pairing access.
        EXECUTOR.execute {
            val result = runCatching { ProviderRun(context.applicationContext, runID!!).execute(operation!!) }
                .getOrElse { JSONObject().put("status", "failed").put("run_id", runID)
                    .put("error", "fixture_initialization_failed").put("error_type", it.javaClass.simpleName) }
            try {
                pending.resultCode = if (result.optString("status") in setOf("prepared", "passed", "cleaned", "diagnosed")) 0 else 3
                pending.resultData = result.toString()
            } finally { pending.finish() }
        }
    }

    companion object {
        const val ACTION = "com.xopmc.galaxybridge.QA_DOWNLOADS_PROVIDER"
        // Caller attestation, not a hardware serial read. The host must additionally use adb -s.
        const val TARGET_SERIAL = "TESTPHONE01"
        private val EXECUTOR = Executors.newSingleThreadExecutor()
    }
}

private class ProviderRun(private val context: Context, private val runID: String) {
    private val directory = File(context.filesDir, "downloads-provider-qa/$runID")
    private val stateFile = AtomicFile(File(directory, "session.json"))
    private val prefix = "gb-qa-$runID"
    private val owner = "qa-$runID"
    private val allocationEvents = JSONArray()
    private val storage = AndroidPendingDownloadsStorage(context) { event ->
        val detail = JSONObject().put("stage", event.stage)
        event.exceptionType?.let { detail.put("exception_type", it) }
        event.rowFound?.let { detail.put("row_found", it) }
        event.ownerMatches?.let { detail.put("owner_matches", it) }
        event.pathMatches?.let { detail.put("path_matches", it) }
        event.pending?.let { detail.put("pending", it) }
        allocationEvents.put(detail)
    }
    private val items = mutableListOf<PendingDownload>()
    private var stage = "new"
    private var currentCheck = "initialization"
    private val report = JSONObject().put("run_id", runID)
    private val checks = JSONArray()

    private val trackedStorage = object : PendingDownloadStorage by storage {
        override fun allocate(name: String, mimeType: String): PendingDownload? {
            check(name.startsWith(prefix)) { "fixture_name_scope" }
            val before = exactRows(name).map { it.item.id }.toSet()
            val item = storage.allocate(name, mimeType)
            if (item == null) {
                diagnoseRows(name, before)
                return null
            }
            items.add(item)
            try { persist() } catch (error: Exception) {
                storage.deletePending(item)
                throw error
            }
            return item
        }
    }

    fun execute(operation: String): JSONObject {
        try {
            if (stateFile.baseFile.exists() || File(directory, "session.json.bak").exists()) restore()
            if (operation == "diagnose") {
                currentCheck = "diagnose_prior_allocation"
                check(stage == "new" && stateFile.baseFile.exists())
                // Recovery of a previously failed prepare: its durable UUID ledger predates
                // allocation. Only that exact generated pending name is eligible for recovery.
                diagnoseRows("$prefix-payload.bin", emptySet())
                return report.put("status", "diagnosed")
            }
            if (operation == "cleanup") {
                currentCheck = "exact_uri_cleanup"
                cleanup()
                return report.put("status", "cleaned").put("cleanup_remaining", 0)
            }
            check(directory.exists() || directory.mkdirs()) { "fixture_directory" }
            if (operation == "prepare") prepare() else resume()
        } catch (error: Exception) {
            report.put("status", "failed").put("error", currentCheck)
                .put("error_type", error.javaClass.simpleName)
            // Keep the exact-URI ledger for explicit cleanup after a failed/incomplete run.
            report.put("cleanup_required", items.isNotEmpty())
        }
        return report.put("checks", checks).put("allocation_events", allocationEvents)
    }

    private fun prepare() {
        currentCheck = "fresh_run"
        check(stage == "new") { "use_fresh_run_id" }
        persist()
        val bytes = payload(1)
        val manifest = manifest("resume", "payload.bin", bytes)
        SQLiteDownloadJournal(QaDatabaseContext(context, directory)).use { journal ->
            val receiver = ResumableDownloadsTransfer(trackedStorage, journal)
            currentCheck = "allocate_real_pending_item"
            expect(receiver.accept(owner, manifest), 0, false)
            currentCheck = "durable_partial_chunk"
            expect(receiver.append(owner, SafIncomingChunk(manifest.transferId, 0, bytes.copyOfRange(0, CUT))), CUT.toLong(), false)
            val checkpoint = requireNotNull(journal.load(manifest.transferId))
            check(checkpoint.phase == DownloadPhase.RECEIVING && checkpoint.offset == CUT.toLong())
            check(checkpoint.prefix.contentEquals(sha(bytes.copyOfRange(0, CUT))))
            check(storage.resolve(checkpoint.item)?.pending == true)
            verifyContent(checkpoint.item, bytes.copyOfRange(0, CUT))
            report.put("pending_uri", checkpoint.item.id).put("checkpoint_offset", CUT)
            checks.put("provider_pending_partial_sha")
        }
        // Closing SQLite before returning makes the next explicit broadcast reconstruct both
        // receiver and SQLite helper. No singleton or live core digest crosses this boundary.
        stage = "prepared"
        persist()
        report.put("status", "prepared").put("next_operation", "resume")
    }

    private fun resume() {
        currentCheck = "restored_prepared_run"
        check(stage == "prepared")
        val bytes = payload(1)
        val manifest = manifest("resume", "payload.bin", bytes)
        SQLiteDownloadJournal(QaDatabaseContext(context, directory)).use { journal ->
            val receiver = ResumableDownloadsTransfer(trackedStorage, journal)
            currentCheck = "new_receiver_checkpoint_resume"
            expect(receiver.accept(owner, manifest), CUT.toLong(), false)
            checks.put("new_receiver_sqlite_resume")
            currentCheck = "complete_and_publish"
            val completed = receiver.append(owner, SafIncomingChunk(manifest.transferId, CUT.toLong(), bytes.copyOfRange(CUT, bytes.size)))
            expect(completed, bytes.size.toLong(), true)
            val original = requireNotNull(journal.load(manifest.transferId)).item
            check(storage.resolve(original)?.pending == false)
            verifyContent(original, bytes)
            check(completed.publishedName == storage.resolve(original)?.name)
            checks.put("published_full_sha")
            report.put("sha256", sha(bytes).hex()).put("original_name", completed.publishedName)

            currentCheck = "same_name_collision_preserves_original"
            val otherBytes = payload(2)
            // Use the actual published name so even provider normalization cannot skip collision.
            val collision = SafIncomingManifest("$prefix-collision", requireNotNull(completed.publishedName),
                otherBytes.size.toLong(), "application/octet-stream", sha(otherBytes))
            val accepted = receiver.accept(owner, collision)
            var collisionReceipt = accepted
            if (accepted.result.failureReason.isEmpty()) {
                expect(accepted, 0, false)
                collisionReceipt = receiver.append(owner, SafIncomingChunk(collision.transferId, 0, otherBytes))
            }
            verifyContent(original, bytes)
            check(storage.resolve(original)?.pending == false)
            if (collisionReceipt.result.complete) {
                val copy = requireNotNull(journal.load(collision.transferId)).item
                check(copy.id != original.id && copy.identity != original.identity && copy.name != original.name)
                check(!requireNotNull(storage.resolve(copy)).pending)
                verifyContent(copy, otherBytes)
                report.put("collision_policy", "distinct_name").put("collision_name", copy.name)
            } else {
                // Explicit collision rejection is also non-destructive; generic IO failure is not a pass.
                check(collisionReceipt.result.failureReason == "destination_exists")
                report.put("collision_policy", "destination_exists")
            }
            checks.put("same_name_original_sha_preserved")

            currentCheck = "cancel_unpublished_exact_item"
            val cancelledManifest = manifest("cancel", "cancel.bin", payload(3))
            expect(receiver.accept(owner, cancelledManifest), 0, false)
            val cancelItem = requireNotNull(journal.load(cancelledManifest.transferId)).item
            val partial = payload(3).copyOfRange(0, CUT)
            expect(receiver.append(owner, SafIncomingChunk(cancelledManifest.transferId, 0, partial)), CUT.toLong(), false)
            check(storage.resolve(cancelItem)?.pending == true)
            val cancelled = receiver.cancel(owner, cancelledManifest.transferId)
            check(!cancelled.result.complete && cancelled.result.failureReason == "transfer_cancelled")
            check(storage.isAbsent(cancelItem))
            check(journal.load(cancelledManifest.transferId)?.phase == DownloadPhase.CANCELLED)
            val repeated = ResumableDownloadsTransfer(trackedStorage, journal).cancel(owner, cancelledManifest.transferId)
            check(repeated.result.failureReason == "transfer_cancelled" && storage.isAbsent(cancelItem))
            verifyContent(original, bytes)
            checks.put("unpublished_cancel_confirmed_absent")
            report.put("cancel_confirmed", true)
        }
        stage = "complete"
        persist()
        currentCheck = "exact_uri_cleanup"
        cleanup()
        checks.put("all_allocated_uris_absent")
        report.put("status", "passed").put("cleanup_remaining", 0)
    }

    private fun manifest(suffix: String, name: String, bytes: ByteArray) = SafIncomingManifest(
        "$prefix-$suffix", "$prefix-$name", bytes.size.toLong(), "application/octet-stream", sha(bytes),
    )
    private fun payload(seed: Int) = ByteArray(524_421) { index -> ((index * 31) xor (seed * 17)).toByte() }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun expect(receipt: DownloadReceipt, offset: Long, complete: Boolean) {
        val valid = receipt.result.failureReason.isEmpty() && receipt.result.confirmedOffset == offset && receipt.result.complete == complete
        if (!valid) report.put("failure_reason", receipt.result.failureReason)
            .put("observed_offset", receipt.result.confirmedOffset).put("observed_complete", receipt.result.complete)
        check(valid)
    }
    private fun verifyContent(item: PendingDownload, expected: ByteArray) {
        // Independent ContentResolver read, not the adapter's hashing implementation.
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        requireNotNull(context.contentResolver.openInputStream(Uri.parse(item.id))).use { stream ->
            val buffer = ByteArray(32 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count == -1) break
                check(count > 0)
                digest.update(buffer, 0, count)
                size += count
                check(size <= expected.size)
            }
        }
        check(size == expected.size.toLong() && MessageDigest.isEqual(digest.digest(), sha(expected)))
    }

    private fun persist() {
        val rows = JSONArray()
        items.forEach { item -> rows.put(JSONObject().put("id", item.id).put("identity", item.identity)
            .put("name", item.name).put("pending", item.pending)) }
        val bytes = JSONObject().put("run_id", runID).put("stage", stage).put("items", rows).toString().toByteArray()
        val stream = stateFile.startWrite()
        try { stream.write(bytes); stateFile.finishWrite(stream) }
        catch (error: Exception) { stateFile.failWrite(stream); throw error }
    }
    private fun restore() {
        val state = JSONObject(String(stateFile.readFully(), Charsets.UTF_8))
        check(state.getString("run_id") == runID)
        stage = state.getString("stage")
        val rows = state.getJSONArray("items")
        check(rows.length() <= 4)
        repeat(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            check(row.getString("name").startsWith(prefix))
            items.add(PendingDownload(row.getString("id"), row.getString("identity"), row.getString("name"), row.getBoolean("pending")))
        }
    }
    private fun cleanup() {
        // Never discover targets by filename, collection query, pairing or production journal.
        for (item in items) {
            check(item.name.startsWith(prefix))
            if (storage.isAbsent(item)) continue
            if (item.identity.isEmpty()) {
                // An insert returned a row but inspect could not open its not-yet-materialized
                // file. A witnessed exact row can be removed only while still pending and
                // still matching all recorded QA metadata; never adopt a published final.
                check(item.pending)
                val row = exactRows(item.name).singleOrNull { it.item.id == item.id }
                check(row != null && row.ownerMatches && row.pathMatches && row.item.pending && row.item.name == item.name)
                check(context.contentResolver.delete(Uri.parse(item.id),
                    "${MediaStore.MediaColumns.IS_PENDING}=1 AND ${MediaStore.MediaColumns.DISPLAY_NAME}=? AND " +
                        "${MediaStore.MediaColumns.OWNER_PACKAGE_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
                    arrayOf(item.name, context.packageName, QA_DIRECTORY)) == 1)
            } else {
                val current = requireNotNull(storage.resolve(item))
                check(current.identity == item.identity && current.name.startsWith(prefix))
                check(context.contentResolver.delete(Uri.parse(item.id), null, null) == 1)
            }
            check(storage.isAbsent(item))
        }
        // These are all private fixture files, not the production downloads-checkpoints.db.
        val allowed = setOf("session.json", "session.json.bak", "session.json.new", "downloads-checkpoints.db",
            "downloads-checkpoints.db-journal", "downloads-checkpoints.db-wal", "downloads-checkpoints.db-shm")
        val files = directory.listFiles().orEmpty()
        check(files.all { it.isFile && it.name in allowed })
        files.forEach { check(it.delete()) }
        check(!directory.exists() || directory.delete())
    }

    private data class ExactQaRow(val item: PendingDownload, val ownerMatches: Boolean, val pathMatches: Boolean)

    private fun exactRows(name: String): List<ExactQaRow> {
        check(name.startsWith(prefix))
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.IS_PENDING, MediaStore.MediaColumns.OWNER_PACKAGE_NAME, MediaStore.MediaColumns.RELATIVE_PATH)
        // Read-only diagnostic: do not hide metadata mismatches or an unpublished row.
        // Every query is still constrained to one exact synthetic UUID filename.
        val arguments = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.MediaColumns.DISPLAY_NAME}=?")
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(name))
            putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
        }
        return requireNotNull(context.contentResolver.query(collection, projection, arguments, null)).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    check(cursor.getString(1) == name)
                    add(ExactQaRow(PendingDownload(ContentUris.withAppendedId(collection, cursor.getLong(0)).toString(),
                        "", name, cursor.getInt(2) == 1), cursor.getString(3) == context.packageName,
                        cursor.getString(4) == QA_DIRECTORY))
                }
            }
        }
    }

    private fun diagnoseRows(name: String, before: Set<String>) {
        val rows = exactRows(name)
        val fresh = rows.filter { it.item.id !in before }
        val diagnostics = JSONArray()
        report.put("allocation_row_count", rows.size).put("allocation_new_row_count", fresh.size)
        for (candidate in fresh) {
            val row = candidate.item
            val diagnostic = JSONObject().put("owner_matches", candidate.ownerMatches)
                .put("path_matches", candidate.pathMatches).put("pending", row.pending)
            var identity = ""
            try {
                requireNotNull(context.contentResolver.openFileDescriptor(Uri.parse(row.id), "r")).use {
                    val stat = Os.fstat(it.fileDescriptor)
                    identity = "${stat.st_dev}:${stat.st_ino}"
                }
                diagnostic.put("read_open", "ok")
            } catch (error: Exception) {
                diagnostic.put("read_open", "failed").put("read_open_error", error.javaClass.simpleName)
            }
            diagnostics.put(diagnostic)
            if (fresh.size == 1 && candidate.ownerMatches && candidate.pathMatches && row.pending && items.none { it.id == row.id }) {
                items.add(row.copy(identity = identity))
                persist()
            }
        }
        report.put("allocation_rows", diagnostics)
    }

    companion object {
        private const val CUT = 131_072
        private const val QA_DIRECTORY = "Download/GalaxyBridge/"
    }
}

/** The production journal schema/transactions are unchanged, but never open the real app DB. */
private class QaDatabaseContext(base: Context, private val directory: File) : ContextWrapper(base) {
    override fun getDatabasePath(name: String): File {
        require(name == "downloads-checkpoints.db")
        check(directory.exists() || directory.mkdirs())
        return File(directory, name)
    }
    override fun openOrCreateDatabase(name: String, mode: Int, factory: SQLiteDatabase.CursorFactory?): SQLiteDatabase =
        SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name), factory)
    override fun openOrCreateDatabase(name: String, mode: Int, factory: SQLiteDatabase.CursorFactory?,
        errorHandler: DatabaseErrorHandler?): SQLiteDatabase =
        SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name).path, factory, errorHandler)
}
