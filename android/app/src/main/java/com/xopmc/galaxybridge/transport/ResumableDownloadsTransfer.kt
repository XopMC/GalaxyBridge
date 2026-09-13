package com.xopmc.galaxybridge.transport

import java.security.MessageDigest

/** All storage methods address an exact allocated item, never a name lookup. */
internal data class PendingDownload(val id: String, val identity: String, val name: String, val pending: Boolean)
internal data class DownloadReceipt(val result: SafTransferResult, val publishedName: String? = null)
internal enum class DownloadPhase { RECEIVING, VERIFIED, COMPLETED, CANCELLED }
internal data class DownloadCheckpoint(
    val owner: String,
    val manifest: SafIncomingManifest,
    val item: PendingDownload,
    val offset: Long,
    val prefix: ByteArray,
    val phase: DownloadPhase,
    val updatedAt: Long,
)
internal interface DownloadJournal {
    /** A malformed existing entry must throw, not appear absent. */
    fun load(id: String): DownloadCheckpoint?
    /** true means the checkpoint is durable; false must retain the old logical value. */
    fun store(record: DownloadCheckpoint): Boolean
    fun all(): List<DownloadCheckpoint>
    fun unsettled(): List<DownloadCheckpoint> = all().filter { it.phase == DownloadPhase.RECEIVING ||
        it.phase == DownloadPhase.VERIFIED || (it.phase == DownloadPhase.CANCELLED && it.item.pending) }
    fun activeCount(): Long = unsettled().size.toLong()
}
internal interface PendingDownloadStorage {
    fun allocate(name: String, mimeType: String): PendingDownload?
    fun resolve(item: PendingDownload): PendingDownload?
    fun length(item: PendingDownload): Long?
    fun truncate(item: PendingDownload, length: Long): Boolean
    /** Must flush file data before returning true. */
    fun write(item: PendingDownload, offset: Long, bytes: ByteArray): Boolean
    fun hashPrefix(item: PendingDownload, length: Long, digest: MessageDigest): Boolean
    fun matches(item: PendingDownload, offset: Long, bytes: ByteArray): Boolean
    /** Publish only this exact item, preserving every other destination. null means no ACK. */
    fun publish(item: PendingDownload): PendingDownload?
    fun deletePending(item: PendingDownload): Boolean
    /** True only for a confirmed absent provider row, never for an IO/permission failure. */
    fun isAbsent(item: PendingDownload): Boolean
}

/**
 * The owner is derived from the authenticated pairing, never from a wire manifest. Use one
 * instance for all FILE channels. Calls perform disk IO and belong on a background executor.
 * Publication is deliberately a strategy seam: generic SAF rename is not a valid strategy.
 */
internal class ResumableDownloadsTransfer(
    private val storage: PendingDownloadStorage,
    private val journal: DownloadJournal,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private data class Session(val record: DownloadCheckpoint, val digest: MessageDigest)
    private val sessions = LinkedHashMap<String, Session>()

    @Synchronized
    fun accept(owner: String, manifest: SafIncomingManifest): DownloadReceipt = guarded(manifest.transferId) {
        requireValid(owner, manifest)
        var record = journal.load(manifest.transferId)
        if (record == null) {
            check(journal.activeCount() < MAX_SESSIONS) { "transfer_capacity_exhausted" }
            val item = storage.allocate(manifest.relativeName, manifest.mimeType)
                ?: fail("storage_allocation_failed")
            check(item.pending) { "pending_ownership_unavailable" }
            record = DownloadCheckpoint(owner, manifest.copy(sha256 = manifest.sha256.copyOf()), item,
                0, digest().digest(), DownloadPhase.RECEIVING, clock())
            if (!journal.store(record)) {
                storage.deletePending(item)
                fail("transfer_state_persistence_failed")
            }
        }
        check(record.owner == owner) { "transfer_owner_mismatch" }
        // A pre-manifest cancellation intentionally lacks file metadata. Its owner-scoped
        // ID is final; no later manifest may turn that tombstone back into a transfer.
        if (record.phase == DownloadPhase.CANCELLED) return@guarded settleCancellation(record)
        check(sameManifest(record.manifest, manifest)) { "transfer_manifest_mismatch" }
        reconcile(record)
    }

    @Synchronized
    fun append(owner: String, chunk: SafIncomingChunk): DownloadReceipt = guarded(chunk.transferId) {
        val record = journal.load(chunk.transferId) ?: fail("transfer_manifest_required")
        check(record.owner == owner) { "transfer_owner_mismatch" }
        if (record.phase != DownloadPhase.RECEIVING) return@guarded reconcile(record)
        check(chunk.content.isNotEmpty() && chunk.content.size <= CHUNK_SIZE) { "invalid_chunk_size" }
        val session = recover(record)
        val end = checkedAddOffset(chunk.offset, chunk.content.size) ?: fail("unexpected_offset")
        if (chunk.offset < record.offset) {
            check(end <= record.offset && storage.matches(record.item, chunk.offset, chunk.content)) {
                "conflicting_duplicate"
            }
            return@guarded receipt(record)
        }
        check(chunk.offset == record.offset && end <= record.manifest.size) { "unexpected_offset" }
        check(storage.write(record.item, record.offset, chunk.content)) { "storage_write_failed" }
        session.digest.update(chunk.content)
        val next = record.copy(offset = end, prefix = snapshot(session.digest), updatedAt = clock())
        check(journal.store(next)) { "transfer_state_persistence_failed" }
        sessions[chunk.transferId] = Session(next, session.digest)
        if (end == next.manifest.size) finish(next) else receipt(next)
    }

    @Synchronized
    fun cancel(owner: String, id: String): DownloadReceipt = guarded(id) {
        requireValidIdentity(owner, id)
        val record = journal.load(id)
        if (record == null) {
            val emptyProof = digest().digest()
            val tombstone = DownloadCheckpoint(owner,
                SafIncomingManifest(id, "", 0, "", emptyProof.copyOf()),
                PendingDownload("", "", "", false), 0, emptyProof, DownloadPhase.CANCELLED, clock())
            check(journal.store(tombstone)) { "transfer_state_persistence_failed" }
            return@guarded receipt(tombstone, "transfer_cancelled")
        }
        check(record.owner == owner) { "transfer_owner_mismatch" }
        if (record.phase == DownloadPhase.CANCELLED) return@guarded settleCancellation(record)
        // A verified item may have been published before a crash lost the final receipt.
        if (record.phase == DownloadPhase.COMPLETED ||
            (record.phase == DownloadPhase.VERIFIED && storage.resolve(record.item)?.pending == false)) {
            return@guarded reconcile(record)
        }
        val cancelled = record.copy(phase = DownloadPhase.CANCELLED, updatedAt = clock())
        check(journal.store(cancelled)) { "transfer_state_persistence_failed" }
        sessions.remove(id)
        settleCancellation(cancelled)
    }

    private fun settleCancellation(record: DownloadCheckpoint): DownloadReceipt {
        check(record.phase == DownloadPhase.CANCELLED)
        if (!record.item.pending) return receipt(record, "transfer_cancelled")
        val current = storage.resolve(record.item)
        if (current == null) {
            check(storage.isAbsent(record.item)) { "pending_cleanup_failed" }
        } else {
            // Never interpret a user-visible final (or a replaced item) as a removable partial.
            check(sameItem(record.item, current) && current.pending) { "pending_cleanup_failed" }
            check(storage.deletePending(record.item)) { "pending_cleanup_failed" }
        }
        val settled = record.copy(item = record.item.copy(pending = false), updatedAt = clock())
        check(journal.store(settled)) { "transfer_state_persistence_failed" }
        return receipt(settled, "transfer_cancelled")
    }

    private fun reconcile(record: DownloadCheckpoint): DownloadReceipt = when (record.phase) {
        DownloadPhase.CANCELLED -> settleCancellation(record)
        DownloadPhase.COMPLETED -> receipt(record) // Durable receipt, never read or delete a user's final file.
        DownloadPhase.VERIFIED -> finish(record)
        DownloadPhase.RECEIVING -> {
            recover(record)
            if (record.offset == record.manifest.size) finish(record) else receipt(record)
        }
    }

    private fun recover(record: DownloadCheckpoint): Session {
        check(record.offset in 0..record.manifest.size && record.prefix.size == 32) { "checkpoint_invalid" }
        val item = storage.resolve(record.item) ?: fail("transfer_document_missing")
        check(item.pending && sameItem(record.item, item)) { "transfer_document_ownership_mismatch" }
        sessions[record.manifest.transferId]?.let {
            if (it.record.offset == record.offset && it.record.prefix.contentEquals(record.prefix) &&
                it.record.item == record.item && storage.length(item) == record.offset) return it
        }
        val size = storage.length(item) ?: fail("storage_read_failed")
        check(size >= record.offset) { "checkpoint_prefix_mismatch" }
        val hash = digest()
        check(storage.hashPrefix(item, record.offset, hash) &&
            MessageDigest.isEqual(snapshot(hash), record.prefix)) { "checkpoint_prefix_mismatch" }
        check(storage.resolve(record.item) == item && storage.length(item) == size) { "checkpoint_changed" }
        if (size > record.offset) check(storage.truncate(item, record.offset)) { "storage_truncate_failed" }
        if (sessions.size >= MAX_SESSIONS) sessions.remove(sessions.keys.first())
        return Session(record, hash).also { sessions[record.manifest.transferId] = it }
    }

    private fun finish(record: DownloadCheckpoint): DownloadReceipt {
        check(record.offset == record.manifest.size && record.prefix.contentEquals(record.manifest.sha256)) {
            "sha256_mismatch"
        }
        val current = storage.resolve(record.item) ?: fail("transfer_document_missing")
        check(sameItem(record.item, current)) { "transfer_document_ownership_mismatch" }
        // One full disk verification before publication, not per-chunk quadratic hashing.
        val verified = digest()
        check(storage.length(current) == record.manifest.size &&
            storage.hashPrefix(current, record.manifest.size, verified) &&
            MessageDigest.isEqual(verified.digest(), record.manifest.sha256) &&
            storage.length(current) == record.manifest.size && storage.resolve(record.item) == current) {
            "sha256_mismatch"
        }
        check(current.pending || record.phase == DownloadPhase.VERIFIED) { "unexpected_publication" }
        val prepared = record.copy(phase = DownloadPhase.VERIFIED, updatedAt = clock())
        check(journal.store(prepared)) { "transfer_state_persistence_failed" }
        val published = if (current.pending) storage.publish(current) ?: fail("publication_unavailable") else current
        check(!published.pending && sameItem(record.item, published)) {
            "publication_identity_mismatch"
        }
        val complete = prepared.copy(phase = DownloadPhase.COMPLETED, item = published, updatedAt = clock())
        check(journal.store(complete)) { "transfer_state_persistence_failed" }
        sessions.remove(record.manifest.transferId)
        return receipt(complete)
    }

    private fun guarded(id: String, work: () -> DownloadReceipt): DownloadReceipt = try { work() } catch (error: Exception) {
        sessions.remove(id)
        // Unknown storage exceptions never disclose paths, content or provider diagnostics on the wire.
        val reason = error.message?.takeIf { it in FAILURES } ?: "transfer_storage_failed"
        DownloadReceipt(SafTransferResult(id, 0, false, reason))
    }
    private fun receipt(record: DownloadCheckpoint, failure: String = "") = DownloadReceipt(
        SafTransferResult(record.manifest.transferId, record.offset, record.phase == DownloadPhase.COMPLETED, failure),
        record.item.name.takeIf { record.phase == DownloadPhase.COMPLETED },
    )
    private fun requireValidIdentity(owner: String, id: String) {
        check(owner.isNotBlank() && owner.length <= 512 && id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "invalid_manifest" }
    }
    private fun requireValid(owner: String, m: SafIncomingManifest) {
        requireValidIdentity(owner, m.transferId)
        check(m.relativeName.isNotBlank() && m.relativeName.toByteArray().size <= 240 &&
            m.relativeName != "." && m.relativeName != ".." && !m.relativeName.startsWith(".") &&
            m.relativeName.none { it == '/' || it == '\\' || it.isISOControl() } &&
            m.size in 0..MAX_SIZE && m.sha256.size == 32 && m.mimeType.length <= 256) { "invalid_manifest" }
    }
    private fun sameManifest(a: SafIncomingManifest, b: SafIncomingManifest) = a.transferId == b.transferId &&
        a.relativeName == b.relativeName && a.size == b.size && a.mimeType == b.mimeType && a.sha256.contentEquals(b.sha256)
    private fun sameItem(a: PendingDownload, b: PendingDownload) = a.id == b.id && a.identity == b.identity
    private fun digest() = MessageDigest.getInstance("SHA-256")
    private fun snapshot(digest: MessageDigest) = (digest.clone() as MessageDigest).digest()
    private fun fail(reason: String): Nothing = throw IllegalStateException(reason)
    companion object {
        const val MAX_SIZE = 10L * 1024 * 1024 * 1024
        const val CHUNK_SIZE = 1024 * 1024
        private const val MAX_SESSIONS = 8
        private val FAILURES = setOf("transfer_capacity_exhausted", "storage_allocation_failed", "pending_ownership_unavailable",
            "destination_exists", "transfer_state_persistence_failed", "transfer_manifest_mismatch", "transfer_manifest_required",
            "transfer_owner_mismatch", "invalid_chunk_size", "unexpected_offset", "conflicting_duplicate", "storage_write_failed",
            "pending_cleanup_failed", "checkpoint_invalid", "transfer_document_missing", "transfer_document_ownership_mismatch",
            "storage_read_failed", "checkpoint_prefix_mismatch", "checkpoint_changed", "storage_truncate_failed", "sha256_mismatch",
            "unexpected_publication", "publication_unavailable", "publication_identity_mismatch", "invalid_manifest")
    }
}
