package com.xopmc.galaxybridge.transport

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.UUID

internal enum class OutgoingFilePhase { PREPARED, QUEUED, PAUSED, CANCEL_REQUESTED, COMPLETED, CANCELLED }
internal data class OutgoingFileRecord(
    val id: String,
    val owner: String,
    val name: String,
    val size: Long,
    val mimeType: String,
    val sha256: ByteArray,
    val phase: OutgoingFilePhase = OutgoingFilePhase.QUEUED,
    val publishedName: String = "",
)

/** No Android dependencies: the real filesystem/crash boundaries are exercised by JVM tests. */
internal class OutgoingFileStore(
    private val root: File,
    private val syncDirectory: (File) -> Unit,
) {
    private val reservations = mutableSetOf<String>()
    data class Listing(val records: List<OutgoingFileRecord>, val rejected: Int)

    fun prepare(owner: String, name: String, mimeType: String, open: () -> InputStream,
                cancelled: () -> Boolean = { false },
                initialPhase: OutgoingFilePhase = OutgoingFilePhase.QUEUED): OutgoingFileRecord {
        require(initialPhase == OutgoingFilePhase.QUEUED || initialPhase == OutgoingFilePhase.PREPARED)
        require(validOwner(owner) && validName(name) && mimeType.length <= 255) { "invalid_transfer" }
        val id = UUID.randomUUID().toString()
        val directory = synchronized(this) {
            prepareRoot()
            val existing = list()
            check(existing.records.count { !it.terminal } + existing.rejected + reservations.size < MAX_ACTIVE) { "transfer_capacity_exhausted" }
            val directory = directory(id)
            Files.createDirectory(directory.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
            reservations.add(id)
            directory
        }
        var committed = false
        try {
            val payload = File(directory, "payload")
            Files.createFile(payload.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            open().use { input ->
                FileOutputStream(payload).use { output ->
                    val buffer = ByteArray(CHUNK_SIZE)
                    while (true) {
                        check(!cancelled() && !Thread.currentThread().isInterrupted) { "transfer_cancelled" }
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count == 0) continue
                        check(size <= MAX_SIZE - count) { "file_too_large" }
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        size += count
                    }
                    output.fd.sync()
                }
            }
            check(!cancelled()) { "transfer_cancelled" }
            Files.setPosixFilePermissions(payload.toPath(), PosixFilePermissions.fromString("r--------"))
            val record = OutgoingFileRecord(id, owner, name, size,
                mimeType.ifBlank { "application/octet-stream" }, digest.digest(), initialPhase)
            synchronized(this) {
                check(!cancelled()) { "transfer_cancelled" }
                write(record)
                committed = true
            }
            return record
        } finally {
            synchronized(this) {
                reservations.remove(id)
                if (!committed && !File(directory, "record").exists()) {
                    // This invocation allocated this exact UUID directory. Never follow links.
                    deletePrivateFile(File(directory, "payload"))
                    deletePrivateFile(File(directory, "record.new"))
                    // A failed fsync after rename is uncertain, not safe to erase as uncommitted.
                    Files.deleteIfExists(directory.toPath())
                }
            }
        }
    }

    @Synchronized fun list(): Listing {
        if (!Files.exists(root.toPath(), NOFOLLOW_LINKS)) return Listing(emptyList(), 0)
        validateDirectory(root)
        val records = mutableListOf<OutgoingFileRecord>()
        var rejected = 0
        root.listFiles()?.forEach { directory ->
            if (!validID(directory.name) || directory.name in reservations) return@forEach
            try {
                validateDirectory(directory)
                val record = load(directory.name)
                if (record == null) {
                    // Interrupted preparation is not resumable; remove only our fixed payload names.
                    deletePrivateFile(File(directory, "payload"))
                    deletePrivateFile(File(directory, "record.new"))
                    Files.delete(directory.toPath())
                } else {
                    records += record
                    if (record.terminal && Files.exists(File(directory, "payload").toPath(), NOFOLLOW_LINKS)) {
                        deletePrivateFile(File(directory, "payload"))
                        syncDirectory(directory)
                    }
                }
            } catch (_: Exception) { rejected++ }
        }
        return Listing(records.sortedBy { it.id }, rejected)
    }

    @Synchronized fun load(id: String): OutgoingFileRecord? {
        require(validID(id)) { "invalid_transfer" }
        val directory = directory(id)
        if (!Files.exists(directory.toPath(), NOFOLLOW_LINKS)) return null
        validateDirectory(root); validateDirectory(directory)
        val file = File(directory, "record")
        if (!Files.exists(file.toPath(), NOFOLLOW_LINKS)) return null
        validateFile(file)
        check(file.length() in 1..8192) { "invalid_transfer_record" }
        val record = DataInputStream(FileInputStream(file)).use { input ->
            check(input.readInt() == 1) { "invalid_transfer_record" }
            val identity = input.readUTF(); val owner = input.readUTF(); val name = input.readUTF()
            val size = input.readLong(); val mime = input.readUTF()
            val hash = ByteArray(32); input.readFully(hash)
            val phase = OutgoingFilePhase.valueOf(input.readUTF()); val published = input.readUTF()
            check(input.read() == -1) { "invalid_transfer_record" }
            OutgoingFileRecord(identity, owner, name, size, mime, hash, phase, published)
        }
        check(record.id == id && validOwner(record.owner) && validName(record.name) &&
            record.size in 0..MAX_SIZE && record.mimeType.length <= 255 &&
            (record.publishedName.isEmpty() || validName(record.publishedName))) { "invalid_transfer_record" }
        return record
    }

    @Synchronized fun transition(id: String, owner: String, phase: OutgoingFilePhase,
                                 publishedName: String = ""): OutgoingFileRecord {
        val current = load(id) ?: error("transfer_missing")
        check(current.owner == owner) { "transfer_owner_mismatch" }
        if (current.terminal) return current
        check(current.phase != OutgoingFilePhase.CANCEL_REQUESTED ||
            phase in setOf(OutgoingFilePhase.CANCEL_REQUESTED, OutgoingFilePhase.CANCELLED, OutgoingFilePhase.COMPLETED)) {
            "transfer_cancelled"
        }
        if (phase == OutgoingFilePhase.COMPLETED) require(validName(publishedName)) { "invalid_completion_name" }
        val updated = current.copy(phase = phase, publishedName = publishedName)
        write(updated)
        if (updated.terminal) {
            deletePrivateFile(File(directory(id), "payload"))
            syncDirectory(directory(id))
        }
        return updated
    }

    fun verify(record: OutgoingFileRecord, cancelled: () -> Boolean = { false }) {
        check(!record.terminal && record.phase != OutgoingFilePhase.CANCEL_REQUESTED) { "transfer_cancelled" }
        val payload = File(directory(record.id), "payload")
        validateDirectory(root); validateDirectory(directory(record.id)); validateFile(payload)
        check(payload.length() == record.size) { "source_changed" }
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(payload).use { input ->
            val buffer = ByteArray(CHUNK_SIZE)
            while (true) {
                check(!cancelled()) { "transfer_cancelled" }
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        check(MessageDigest.isEqual(digest.digest(), record.sha256) && payload.length() == record.size) { "source_changed" }
    }

    fun read(record: OutgoingFileRecord, offset: Long): ByteArray {
        require(offset in 0..record.size) { "invalid_confirmed_offset" }
        val current = synchronized(this) { load(record.id) } ?: error("transfer_missing")
        check(current.owner == record.owner && current.phase == OutgoingFilePhase.QUEUED) { "transfer_cancelled" }
        val payload = File(directory(record.id), "payload")
        validateFile(payload)
        check(payload.length() == record.size) { "source_changed" }
        val bytes = ByteArray(minOf(CHUNK_SIZE.toLong(), record.size - offset).toInt())
        RandomAccessFile(payload, "r").use { input -> input.seek(offset); input.readFully(bytes) }
        return bytes
    }

    private fun write(record: OutgoingFileRecord) {
        val directory = directory(record.id)
        validateDirectory(directory)
        val temporary = File(directory, "record.new")
        deletePrivateFile(temporary)
        Files.createFile(temporary.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
        FileOutputStream(temporary).use { file ->
            val output = DataOutputStream(file)
            output.writeInt(1); output.writeUTF(record.id); output.writeUTF(record.owner)
            output.writeUTF(record.name); output.writeLong(record.size); output.writeUTF(record.mimeType)
            output.write(record.sha256); output.writeUTF(record.phase.name); output.writeUTF(record.publishedName)
            output.flush(); file.fd.sync()
        }
        Files.move(temporary.toPath(), File(directory, "record").toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
        syncDirectory(directory); syncDirectory(root)
    }

    private fun prepareRoot() {
        if (!Files.exists(root.toPath(), NOFOLLOW_LINKS)) {
            val parent = requireNotNull(root.parentFile)
            Files.createDirectories(parent.toPath())
            Files.createDirectory(root.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
            syncDirectory(parent)
        }
        validateDirectory(root)
    }
    private fun directory(id: String): File { require(validID(id)); return File(root, id) }
    private fun validateDirectory(file: File) {
        check(Files.isDirectory(file.toPath(), NOFOLLOW_LINKS) && !Files.isSymbolicLink(file.toPath()) &&
            file.canonicalFile == file.absoluteFile) { "unsafe_transfer_storage" }
        check(Files.getPosixFilePermissions(file.toPath()).all {
            it.name.startsWith("OWNER_")
        }) { "unsafe_transfer_storage" }
    }
    private fun validateFile(file: File) {
        check(Files.isRegularFile(file.toPath(), NOFOLLOW_LINKS) && !Files.isSymbolicLink(file.toPath()) &&
            file.canonicalFile == file.absoluteFile) { "unsafe_transfer_storage" }
    }
    private fun deletePrivateFile(file: File) {
        if (!Files.exists(file.toPath(), NOFOLLOW_LINKS)) return
        validateFile(file)
        Files.delete(file.toPath())
    }
    companion object {
        const val MAX_SIZE = 10L * 1024 * 1024 * 1024
        const val CHUNK_SIZE = 1024 * 1024
        const val MAX_ACTIVE = 8
        fun validID(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
        fun validOwner(value: String) = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
        fun validName(value: String) = value.isNotBlank() && value != "." && value != ".." &&
            value.toByteArray(Charsets.UTF_8).size <= 255 && value.none { it == '/' || it == '\\' || it.code < 32 || it.code == 127 }
    }
}

internal val OutgoingFileRecord.terminal: Boolean
    get() = phase == OutgoingFilePhase.COMPLETED || phase == OutgoingFilePhase.CANCELLED
