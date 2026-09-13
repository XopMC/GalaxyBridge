package com.xopmc.galaxybridge.transport

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.LinkedHashMap

private val EMPTY_SHA256: ByteArray = MessageDigest.getInstance("SHA-256").digest()

internal data class SafIncomingManifest(
    val transferId: String,
    val relativeName: String,
    val size: Long,
    val mimeType: String,
    val sha256: ByteArray,
)

internal data class SafIncomingChunk(
    val transferId: String,
    val offset: Long,
    val content: ByteArray,
)

internal data class SafTransferResult(
    val transferId: String,
    val confirmedOffset: Long,
    val complete: Boolean,
    val failureReason: String,
)

internal data class SafDocument(
    val id: String,
    val displayName: String,
)

internal data class SafTransferRecord(
    val transferId: String,
    val treeId: String,
    val documentId: String,
    val temporaryName: String,
    val relativeName: String,
    val size: Long,
    val mimeType: String,
    val sha256: ByteArray,
    val updatedAtMillis: Long,
    val confirmedOffset: Long = 0,
    val prefixSha256: ByteArray? = EMPTY_SHA256.copyOf(),
) {
    fun matches(manifest: SafIncomingManifest, selectedTreeId: String): Boolean =
        transferId == manifest.transferId &&
            treeId == selectedTreeId &&
            relativeName == manifest.relativeName &&
            size == manifest.size &&
            mimeType == manifest.normalizedMimeType() &&
            sha256.contentEquals(manifest.sha256)

    fun hasCheckpointProof(): Boolean =
        confirmedOffset in 0..size && prefixSha256?.size == SHA256_SIZE

    fun hasValidTemporaryOwnershipMetadata(): Boolean =
        temporaryName.isValidSafLeafName() && temporaryName != relativeName

    companion object {
        const val SHA256_SIZE = 32
    }
}

internal interface SafTransferJournal {
    fun load(transferId: String): SafTransferRecord?
    fun store(record: SafTransferRecord): Boolean
    fun remove(transferId: String)
    fun all(): List<SafTransferRecord>
    fun contains(transferId: String): Boolean = load(transferId) != null
}

internal interface SafTransferStorage {
    val selectedTreeId: String?
    fun createTemporary(treeId: String, mimeType: String, displayName: String): SafDocument?
    fun resolve(documentId: String): SafDocument?
    fun supportsResumableWrite(document: SafDocument): Boolean
    fun length(document: SafDocument): Long?
    fun truncate(document: SafDocument, length: Long): Boolean
    fun write(document: SafDocument, offset: Long, bytes: ByteArray): Boolean
    fun updateSha256Prefix(document: SafDocument, length: Long, digest: MessageDigest): Boolean
    fun matches(document: SafDocument, offset: Long, bytes: ByteArray): Boolean
    fun sha256(document: SafDocument): ByteArray?
    fun rename(document: SafDocument, displayName: String): SafDocument?
    fun delete(document: SafDocument): Boolean
    fun finalDocumentExists(treeId: String, displayName: String): Boolean
}

internal object SafTransferRecordCodec {
    fun encode(record: SafTransferRecord): String {
        val prefixSha256 = requireNotNull(record.prefixSha256)
        require(record.hasCheckpointProof())
        require(record.hasValidTemporaryOwnershipMetadata())
        val bytes = ByteArrayOutputStream().use { buffer ->
            DataOutputStream(buffer).use { output ->
                output.writeInt(VERSION)
                output.writeUTF(record.transferId)
                output.writeUTF(record.treeId)
                output.writeUTF(record.documentId)
                output.writeUTF(record.temporaryName)
                output.writeUTF(record.relativeName)
                output.writeLong(record.size)
                output.writeUTF(record.mimeType)
                output.writeInt(record.sha256.size)
                output.write(record.sha256)
                output.writeLong(record.updatedAtMillis)
                output.writeLong(record.confirmedOffset)
                output.writeInt(prefixSha256.size)
                output.write(prefixSha256)
            }
            buffer.toByteArray()
        }
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    fun decode(encoded: String): SafTransferRecord? = runCatching {
        require(encoded.length <= MAX_ENCODED_LENGTH)
        val bytes = Base64.getUrlDecoder().decode(encoded)
        DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            val version = input.readInt()
            require(version == LEGACY_VERSION || version == VERSION)
            val transferId = input.readUTF()
            val treeId = input.readUTF()
            val documentId = input.readUTF()
            val temporaryName = input.readUTF()
            val relativeName = input.readUTF()
            val size = input.readLong()
            val mimeType = input.readUTF()
            val hashLength = input.readInt()
            require(hashLength == SHA256_LENGTH)
            val sha256 = ByteArray(hashLength).also(input::readFully)
            val updatedAtMillis = input.readLong()
            val confirmedOffset: Long
            val prefixSha256: ByteArray?
            if (version == VERSION) {
                confirmedOffset = input.readLong()
                val prefixHashLength = input.readInt()
                require(prefixHashLength == SHA256_LENGTH)
                prefixSha256 = ByteArray(prefixHashLength).also(input::readFully)
            } else {
                confirmedOffset = 0
                prefixSha256 = null
            }
            require(input.available() == 0)
            require(transferId.isNotBlank() && treeId.isNotBlank() && documentId.isNotBlank())
            require(size >= 0 && updatedAtMillis >= 0 && confirmedOffset in 0..size)
            SafTransferRecord(
                transferId,
                treeId,
                documentId,
                temporaryName,
                relativeName,
                size,
                mimeType,
                sha256,
                updatedAtMillis,
                confirmedOffset,
                prefixSha256,
            ).takeIf(SafTransferRecord::hasValidTemporaryOwnershipMetadata)
        }
    }.getOrNull()

    private const val LEGACY_VERSION = 1
    private const val VERSION = 2
    private const val SHA256_LENGTH = 32
    private const val MAX_ENCODED_LENGTH = 16 * 1024
}

/**
 * Receives file chunks directly into a resumable SAF document. No application-private copy is
 * created, so a transfer needs only the destination file's free space rather than twice its size.
 */
internal fun checkedAddOffset(offset: Long, length: Int): Long? {
    if (offset < 0 || length < 0 || offset > Long.MAX_VALUE - length.toLong()) return null
    return offset + length.toLong()
}

internal object SafCheckpointHashing {
    fun updatePrefix(input: InputStream, length: Long, digest: MessageDigest): Boolean {
        if (length < 0) return false
        val buffer = ByteArray(BUFFER_SIZE)
        var remaining = length
        while (remaining > 0) {
            val requested = minOf(buffer.size.toLong(), remaining).toInt()
            val count = input.read(buffer, 0, requested)
            when {
                count < 0 -> return false
                count == 0 -> {
                    val byte = input.read()
                    if (byte < 0) return false
                    digest.update(byte.toByte())
                    remaining--
                }
                else -> {
                    digest.update(buffer, 0, count)
                    remaining -= count.toLong()
                }
            }
        }
        return true
    }

    private const val BUFFER_SIZE = 64 * 1024
}

internal class ResumableSafTransfer(
    private val storage: SafTransferStorage,
    private val journal: SafTransferJournal,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val digestFactory: () -> MessageDigest = { MessageDigest.getInstance("SHA-256") },
) {
    private val mutationLock = Any()
    private val sessions = LinkedHashMap<String, DigestSession>()

    fun accept(manifest: SafIncomingManifest): SafTransferResult = synchronized(mutationLock) {
        acceptLocked(manifest)
    }

    fun append(chunk: SafIncomingChunk): SafTransferResult = synchronized(mutationLock) {
        appendLocked(chunk)
    }

    fun cleanup(nowMillis: Long = this.nowMillis()) = synchronized(mutationLock) {
        val staleBefore = nowMillis - PART_RETENTION_MILLIS
        journal.all().filter { it.updatedAtMillis <= staleBefore }.forEach { record ->
            if (!record.hasCheckpointProof()) return@forEach
            val document = storage.resolve(record.documentId) ?: return@forEach
            if (!ownsTemporary(record, document)) return@forEach
            if (storage.delete(document)) {
                journal.remove(record.transferId)
                sessions.remove(record.transferId)
            }
        }
    }

    fun revoke() = synchronized(mutationLock) {
        journal.all().forEach { record ->
            if (!record.hasCheckpointProof()) return@forEach
            val document = storage.resolve(record.documentId) ?: return@forEach
            if (!ownsTemporary(record, document)) return@forEach
            if (storage.delete(document)) {
                journal.remove(record.transferId)
                sessions.remove(record.transferId)
            }
        }
    }

    private fun acceptLocked(manifest: SafIncomingManifest): SafTransferResult {
        validate(manifest)?.let { return result(manifest.transferId, 0, failure = it) }
        val treeId = storage.selectedTreeId
            ?: return result(manifest.transferId, 0, failure = "storage_folder_unavailable")
        val existing = journal.load(manifest.transferId)
        if (existing != null) {
            if (!existing.matches(manifest, treeId)) {
                return result(manifest.transferId, 0, failure = "transfer_manifest_mismatch")
            }
            if (!existing.hasCheckpointProof()) {
                return result(manifest.transferId, 0, failure = "checkpoint_proof_unavailable")
            }
            val document = storage.resolve(existing.documentId)
                ?: return result(manifest.transferId, 0, failure = "transfer_document_missing")
            val recovery = recover(existing, document, refreshTimestamp = true)
            recovery.failure?.let { return it }
            val recoveredRecord = requireNotNull(recovery.record)
            return if (recoveredRecord.confirmedOffset == recoveredRecord.size) {
                finalize(recoveredRecord)
            } else {
                result(manifest.transferId, recoveredRecord.confirmedOffset)
            }
        }
        if (journal.contains(manifest.transferId)) {
            return result(manifest.transferId, 0, failure = "transfer_state_invalid")
        }

        val digest = newDigest()
            ?: return result(manifest.transferId, 0, failure = "checkpoint_proof_unavailable")
        val initialProof = snapshotDigest(digest)
            ?: return result(manifest.transferId, 0, failure = "checkpoint_proof_unavailable")
        if (journal.all().size >= MAX_ACTIVE_TRANSFERS) {
            return result(manifest.transferId, 0, failure = "too_many_active_transfers")
        }
        if (storage.finalDocumentExists(treeId, manifest.relativeName)) {
            return result(manifest.transferId, 0, failure = "destination_exists")
        }
        val temporaryName = temporaryName(manifest.transferId)
        val document = storage.createTemporary(treeId, manifest.normalizedMimeType(), temporaryName)
            ?: return result(manifest.transferId, 0, failure = "storage_folder_unavailable")
        if (!document.displayName.isValidSafLeafName() || document.displayName == manifest.relativeName) {
            storage.delete(document)
            return result(manifest.transferId, 0, failure = "temporary_name_unavailable")
        }
        if (!storage.supportsResumableWrite(document) || !storage.truncate(document, 0)) {
            storage.delete(document)
            return result(manifest.transferId, 0, failure = "provider_no_resumable_write")
        }
        val record = SafTransferRecord(
            transferId = manifest.transferId,
            treeId = treeId,
            documentId = document.id,
            temporaryName = document.displayName,
            relativeName = manifest.relativeName,
            size = manifest.size,
            mimeType = manifest.normalizedMimeType(),
            sha256 = manifest.sha256.copyOf(),
            updatedAtMillis = nowMillis(),
            confirmedOffset = 0,
            prefixSha256 = initialProof,
        )
        if (!journal.store(record)) {
            storage.delete(document)
            return result(manifest.transferId, 0, failure = "transfer_state_persistence_failed")
        }
        if (!putSession(record, document, digest)) {
            return result(manifest.transferId, 0, failure = "too_many_active_transfers")
        }
        return if (record.size == 0L) finalize(record) else result(manifest.transferId, 0)
    }

    private fun appendLocked(chunk: SafIncomingChunk): SafTransferResult {
        val record = journal.load(chunk.transferId)
            ?: return result(
                chunk.transferId,
                0,
                failure = if (journal.contains(chunk.transferId)) "transfer_state_invalid" else "transfer_manifest_required",
            )
        if (!record.hasCheckpointProof()) {
            return result(chunk.transferId, 0, failure = "checkpoint_proof_unavailable")
        }
        val document = storage.resolve(record.documentId)
            ?: return result(chunk.transferId, 0, failure = "transfer_document_missing")
        if (!ownsTemporary(record, document)) {
            sessions.remove(chunk.transferId)
            return result(chunk.transferId, 0, failure = "transfer_document_ownership_mismatch")
        }
        val session = currentSession(record, document) ?: run {
            val recovery = recover(record, document, refreshTimestamp = false)
            recovery.failure?.let { return it }
            requireNotNull(recovery.session)
        }
        val confirmed = session.record.confirmedOffset
        if (chunk.content.isEmpty() || chunk.content.size > MAX_CHUNK_SIZE) {
            return result(chunk.transferId, confirmed, failure = "invalid_chunk_size")
        }
        val endOffset = checkedAddOffset(chunk.offset, chunk.content.size)
            ?: return result(chunk.transferId, confirmed, failure = "unexpected_offset")
        if (chunk.offset < confirmed) {
            if (endOffset > confirmed) {
                return result(chunk.transferId, confirmed, failure = "unexpected_offset")
            }
            val duplicateMatches = storage.matches(document, chunk.offset, chunk.content)
            return if (duplicateMatches) {
                result(chunk.transferId, confirmed)
            } else {
                result(chunk.transferId, confirmed, failure = "conflicting_duplicate")
            }
        }
        if (chunk.offset != confirmed || endOffset > session.record.size) {
            return result(chunk.transferId, confirmed, failure = "unexpected_offset")
        }
        if (!storage.supportsResumableWrite(document) || !storage.write(document, confirmed, chunk.content)) {
            sessions.remove(chunk.transferId)
            return result(chunk.transferId, confirmed, failure = "provider_no_resumable_write")
        }
        val actualLength = storage.length(document)
        if (actualLength != endOffset) {
            sessions.remove(chunk.transferId)
            return result(chunk.transferId, confirmed, failure = "provider_no_resumable_write")
        }
        session.digest.update(chunk.content)
        val nextProof = snapshotDigest(session.digest)
        if (nextProof == null) {
            sessions.remove(chunk.transferId)
            return result(chunk.transferId, confirmed, failure = "checkpoint_proof_unavailable")
        }
        val nextRecord = session.record.copy(
            updatedAtMillis = nowMillis(),
            confirmedOffset = endOffset,
            prefixSha256 = nextProof,
        )
        if (!journal.store(nextRecord)) {
            sessions.remove(chunk.transferId)
            return result(chunk.transferId, confirmed, failure = "transfer_state_persistence_failed")
        }
        val nextSession = DigestSession(nextRecord, document.id, session.digest)
        sessions[chunk.transferId] = nextSession
        return if (endOffset == nextRecord.size) finalize(nextRecord) else result(chunk.transferId, endOffset)
    }

    private fun recover(
        record: SafTransferRecord,
        document: SafDocument,
        refreshTimestamp: Boolean,
    ): Recovery {
        if (!ownsTemporary(record, document)) {
            sessions.remove(record.transferId)
            return Recovery(failure = result(record.transferId, 0, failure = "transfer_document_ownership_mismatch"))
        }
        if (!storage.supportsResumableWrite(document)) {
            sessions.remove(record.transferId)
            return Recovery(failure = result(record.transferId, 0, failure = "provider_no_resumable_write"))
        }
        val length = storage.length(document)
            ?: return Recovery(failure = result(record.transferId, 0, failure = "provider_no_resumable_write"))
        if (length < record.confirmedOffset) {
            sessions.remove(record.transferId)
            return Recovery(failure = result(record.transferId, 0, failure = "checkpoint_prefix_mismatch"))
        }
        val digest = newDigest()
            ?: return Recovery(failure = result(record.transferId, 0, failure = "checkpoint_proof_unavailable"))
        if (!storage.updateSha256Prefix(document, record.confirmedOffset, digest)) {
            sessions.remove(record.transferId)
            return Recovery(failure = result(record.transferId, 0, failure = "checkpoint_prefix_read_failed"))
        }
        val actualProof = snapshotDigest(digest)
        if (actualProof == null || !MessageDigest.isEqual(actualProof, record.prefixSha256)) {
            sessions.remove(record.transferId)
            return Recovery(failure = result(record.transferId, 0, failure = "checkpoint_prefix_mismatch"))
        }
        val currentDocument = storage.resolve(record.documentId)
            ?: return Recovery(failure = result(record.transferId, 0, failure = "transfer_document_missing"))
        if (!ownsTemporary(record, currentDocument)) {
            sessions.remove(record.transferId)
            return Recovery(failure = result(record.transferId, 0, failure = "transfer_document_ownership_mismatch"))
        }
        val currentLength = storage.length(currentDocument)
            ?: return Recovery(failure = result(record.transferId, 0, failure = "provider_no_resumable_write"))
        if (currentLength != length) {
            sessions.remove(record.transferId)
            return Recovery(failure = result(record.transferId, 0, failure = "checkpoint_changed_during_verification"))
        }
        val recoveredDocument = if (currentLength > record.confirmedOffset) {
            val truncateDocument = storage.resolve(record.documentId)
                ?: return Recovery(failure = result(record.transferId, 0, failure = "transfer_document_missing"))
            if (!ownsTemporary(record, truncateDocument)) {
                sessions.remove(record.transferId)
                return Recovery(
                    failure = result(record.transferId, 0, failure = "transfer_document_ownership_mismatch"),
                )
            }
            if (!storage.truncate(truncateDocument, record.confirmedOffset)) {
                sessions.remove(record.transferId)
                return Recovery(
                    failure = result(record.transferId, record.confirmedOffset, failure = "provider_no_resumable_write"),
                )
            }
            truncateDocument
        } else {
            currentDocument
        }
        val recoveredRecord = if (refreshTimestamp) record.copy(updatedAtMillis = nowMillis()) else record
        if (refreshTimestamp && !journal.store(recoveredRecord)) {
            sessions.remove(record.transferId)
            return Recovery(
                failure = result(record.transferId, record.confirmedOffset, failure = "transfer_state_persistence_failed"),
            )
        }
        if (!putSession(recoveredRecord, recoveredDocument, digest)) {
            return Recovery(
                failure = result(record.transferId, record.confirmedOffset, failure = "too_many_active_transfers"),
            )
        }
        return Recovery(
            record = recoveredRecord,
            session = requireNotNull(sessions[record.transferId]),
        )
    }

    private fun finalize(record: SafTransferRecord): SafTransferResult {
        val currentDocument = storage.resolve(record.documentId)
            ?: return result(record.transferId, 0, failure = "transfer_document_missing")
        if (!ownsTemporary(record, currentDocument)) {
            sessions.remove(record.transferId)
            return result(record.transferId, 0, failure = "transfer_document_ownership_mismatch")
        }
        val actualHash = storage.sha256(currentDocument)
            ?: return result(record.transferId, record.confirmedOffset, failure = "hash_read_failed")
        val postHashDocument = storage.resolve(record.documentId)
            ?: return result(record.transferId, 0, failure = "transfer_document_missing")
        if (!ownsTemporary(record, postHashDocument)) {
            sessions.remove(record.transferId)
            return result(record.transferId, 0, failure = "transfer_document_ownership_mismatch")
        }
        if (storage.length(postHashDocument) != record.size) {
            sessions.remove(record.transferId)
            return result(record.transferId, 0, failure = "checkpoint_changed_during_verification")
        }
        if (!MessageDigest.isEqual(actualHash, record.sha256)) {
            val digest = newDigest()
            val emptyProof = digest?.let(::snapshotDigest)
            if (digest == null || emptyProof == null) {
                sessions.remove(record.transferId)
                return result(record.transferId, record.confirmedOffset, failure = "checkpoint_proof_unavailable")
            }
            val resetRecord = record.copy(
                updatedAtMillis = nowMillis(),
                confirmedOffset = 0,
                prefixSha256 = emptyProof,
            )
            if (!journal.store(resetRecord)) {
                sessions.remove(record.transferId)
                return result(
                    record.transferId,
                    record.confirmedOffset,
                    failure = "transfer_state_persistence_failed",
                )
            }
            sessions.remove(record.transferId)
            val resetDocument = storage.resolve(record.documentId)
                ?: return result(record.transferId, 0, failure = "transfer_document_missing")
            if (!ownsTemporary(resetRecord, resetDocument)) {
                sessions.remove(record.transferId)
                return result(record.transferId, 0, failure = "transfer_document_ownership_mismatch")
            }
            if (!storage.truncate(resetDocument, 0)) {
                sessions.remove(record.transferId)
                return result(record.transferId, 0, failure = "provider_no_resumable_write")
            }
            sessions[record.transferId] = DigestSession(resetRecord, resetDocument.id, digest)
            return result(record.transferId, 0, failure = "sha256_mismatch")
        }
        if (storage.finalDocumentExists(record.treeId, record.relativeName)) {
            return result(record.transferId, record.confirmedOffset, failure = "destination_exists")
        }
        val publicationDocument = storage.resolve(record.documentId)
            ?: return result(record.transferId, 0, failure = "transfer_document_missing")
        if (!ownsTemporary(record, publicationDocument)) {
            sessions.remove(record.transferId)
            return result(record.transferId, 0, failure = "transfer_document_ownership_mismatch")
        }
        if (storage.length(publicationDocument) != record.size) {
            sessions.remove(record.transferId)
            return result(record.transferId, 0, failure = "checkpoint_changed_during_verification")
        }
        val ownedPublicationDocument = storage.resolve(record.documentId)
            ?: return result(record.transferId, 0, failure = "transfer_document_missing")
        if (!ownsTemporary(record, ownedPublicationDocument)) {
            sessions.remove(record.transferId)
            return result(record.transferId, 0, failure = "transfer_document_ownership_mismatch")
        }
        val renamed = storage.rename(ownedPublicationDocument, record.relativeName)
            ?: return result(record.transferId, record.confirmedOffset, failure = "rename_failed")
        if (renamed.displayName != record.relativeName) {
            return result(record.transferId, record.confirmedOffset, failure = "rename_failed")
        }
        journal.remove(record.transferId)
        sessions.remove(record.transferId)
        return result(record.transferId, record.size, complete = true)
    }

    private fun currentSession(record: SafTransferRecord, document: SafDocument): DigestSession? {
        val session = sessions[record.transferId] ?: return null
        return session.takeIf {
            it.documentId == document.id &&
                it.record.confirmedOffset == record.confirmedOffset &&
                it.record.prefixSha256?.contentEquals(record.prefixSha256 ?: ByteArray(0)) == true
        }
    }

    private fun putSession(record: SafTransferRecord, document: SafDocument, digest: MessageDigest): Boolean {
        if (record.transferId !in sessions && sessions.size >= MAX_ACTIVE_TRANSFERS) return false
        sessions[record.transferId] = DigestSession(record, document.id, digest)
        return true
    }

    private fun ownsTemporary(record: SafTransferRecord, document: SafDocument): Boolean =
        record.hasValidTemporaryOwnershipMetadata() &&
            storage.selectedTreeId == record.treeId &&
            record.documentId == document.id &&
            document.displayName == record.temporaryName

    private fun newDigest(): MessageDigest? = runCatching { digestFactory() }.getOrNull()
        ?.takeIf { snapshotDigest(it) != null }

    private fun snapshotDigest(digest: MessageDigest): ByteArray? = runCatching {
        ((digest.clone() as? MessageDigest) ?: return@runCatching null).digest()
    }.getOrNull()?.takeIf { it.size == SafTransferRecord.SHA256_SIZE }

    private fun validate(manifest: SafIncomingManifest): String? = when {
        manifest.transferId.isBlank() || manifest.transferId.length > 128 -> "invalid_transfer_id"
        manifest.relativeName.isBlank() || manifest.relativeName.length > 255 -> "invalid_name"
        manifest.relativeName == "." || manifest.relativeName == ".." -> "invalid_name"
        '/' in manifest.relativeName || '\\' in manifest.relativeName || '\u0000' in manifest.relativeName -> "invalid_name"
        manifest.size < 0 || manifest.size > MAX_TRANSFER_SIZE -> "transfer_too_large"
        manifest.sha256.size != SHA256_SIZE -> "invalid_sha256"
        !manifest.mimeType.isValidMimeType() -> "invalid_mime_type"
        else -> null
    }

    private fun result(
        transferId: String,
        offset: Long,
        complete: Boolean = false,
        failure: String = "",
    ) = SafTransferResult(transferId, offset, complete, failure)

    private fun safeIdentifier(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    private fun temporaryName(transferId: String): String = "$TEMP_PREFIX${safeIdentifier(transferId)}.part"

    private data class DigestSession(
        val record: SafTransferRecord,
        val documentId: String,
        val digest: MessageDigest,
    )

    private data class Recovery(
        val record: SafTransferRecord? = null,
        val session: DigestSession? = null,
        val failure: SafTransferResult? = null,
    )

    internal companion object {
        const val TEMP_PREFIX = ".galaxybridge-"
        const val MAX_CHUNK_SIZE = 1 * 1024 * 1024
        const val MAX_TRANSFER_SIZE = 16L * 1024 * 1024 * 1024 * 1024
        const val PART_RETENTION_MILLIS = 7L * 24 * 60 * 60 * 1_000
        const val MAX_ACTIVE_TRANSFERS = 32
        private const val SHA256_SIZE = 32
    }
}

private fun SafIncomingManifest.normalizedMimeType(): String =
    mimeType.ifBlank { "application/octet-stream" }

private fun String.isValidSafLeafName(): Boolean =
    isNotBlank() &&
        length <= 255 &&
        this != "." &&
        this != ".." &&
        '/' !in this &&
        '\\' !in this &&
        '\u0000' !in this

private fun String.isValidMimeType(): Boolean {
    if (isBlank()) return true
    if (length > 127 || any(Char::isISOControl)) return false
    val slash = indexOf('/')
    if (slash <= 0 || slash == lastIndex || indexOf('/', slash + 1) >= 0) return false
    return substring(0, slash).all(::isMimeToken) && substring(slash + 1).all(::isMimeToken)
}

private fun isMimeToken(character: Char): Boolean =
    character.isLetterOrDigit() || character in "!#$&^_.+-"
