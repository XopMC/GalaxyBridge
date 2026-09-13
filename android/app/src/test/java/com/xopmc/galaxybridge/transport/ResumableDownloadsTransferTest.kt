package com.xopmc.galaxybridge.transport

import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

class ResumableDownloadsTransferTest {
    @Test fun restartTruncatesOnlyUnacknowledgedOwnedTailAndResumesWithLinearHashing() = fixture { f ->
        val data = ByteArray(2 * 1024 * 1024 + 9) { (it % 251).toByte() }
        val m = manifest("resume", data)
        assertEquals(0L, f.receiver().accept("owner", m).result.confirmedOffset)
        val first = data.copyOfRange(0, 1024 * 1024)
        assertEquals(first.size.toLong(), f.receiver().append("owner", SafIncomingChunk(m.transferId, 0, first)).result.confirmedOffset)
        f.storage.file().toFile().appendBytes(byteArrayOf(55, 66))
        val resumed = f.receiver()
        assertEquals(first.size.toLong(), resumed.accept("owner", m).result.confirmedOffset)
        assertEquals(first.size.toLong(), Files.size(f.storage.file()))
        assertFalse(resumed.append("owner", SafIncomingChunk(m.transferId, first.size.toLong(), data.copyOfRange(first.size, first.size * 2))).result.complete)
        val done = resumed.append("owner", SafIncomingChunk(m.transferId, first.size * 2L, data.copyOfRange(first.size * 2, data.size)))
        assertTrue(done.result.complete)
        assertArrayEquals(data, Files.readAllBytes(f.storage.file()))
        assertTrue(f.storage.hashBytes < data.size.toLong() * 3)
    }

    @Test fun failedCheckpointCannotAcknowledgeBytesAndRetryRepairsTail() = fixture { f ->
        val m = manifest("commit", "abcdef".toByteArray())
        val receiver = f.receiver(); receiver.accept("owner", m)
        f.journal.fail = true
        assertEquals("transfer_state_persistence_failed", receiver.append("owner", SafIncomingChunk(m.transferId, 0, "abc".toByteArray())).result.failureReason)
        f.journal.fail = false
        assertEquals(0L, f.receiver().accept("owner", m).result.confirmedOffset)
        assertEquals(0L, Files.size(f.storage.file()))
    }

    @Test fun changedPrefixIsRejectedWithoutTruncatingEvidence() = fixture { f ->
        val m = manifest("corrupt", "abcdef".toByteArray())
        val receiver = f.receiver(); receiver.accept("owner", m)
        receiver.append("owner", SafIncomingChunk(m.transferId, 0, "abc".toByteArray()))
        Files.write(f.storage.file(), "xyzTAIL".toByteArray())
        assertEquals("checkpoint_prefix_mismatch", f.receiver().accept("owner", m).result.failureReason)
        assertEquals(7L, Files.size(f.storage.file()))
    }

    @Test fun publishedReceiptSurvivesLostAckAndCancelNeverDeletesFinal() = fixture { f ->
        val data = "file bytes".toByteArray(); val m = manifest("receipt", data)
        val receiver = f.receiver(); receiver.accept("owner", m)
        f.journal.failPhase = DownloadPhase.COMPLETED
        assertEquals("transfer_state_persistence_failed", receiver.append("owner", SafIncomingChunk(m.transferId, 0, data)).result.failureReason)
        assertFalse(f.storage.current!!.pending)
        f.journal.failPhase = null
        // Cancel is the first operation after the publish/receipt crash boundary.
        assertTrue(f.receiver().cancel("owner", m.transferId).result.complete)
        assertTrue(f.receiver().accept("owner", m).result.complete)
        assertArrayEquals(data, Files.readAllBytes(f.storage.file()))
        Files.delete(f.storage.file())
        assertTrue(f.receiver().accept("owner", m).result.complete) // Historical durable receipt.
    }

    @Test fun existingFinalIsPreservedAndActualCollisionNameIsReturned() = fixture { f ->
        Files.write(f.root.resolve("final.bin"), "existing".toByteArray())
        val data = "new".toByteArray(); val m = manifest("collision", data)
        val receiver = f.receiver(); receiver.accept("owner", m)
        val result = receiver.append("owner", SafIncomingChunk(m.transferId, 0, data))
        assertTrue(result.result.complete)
        assertEquals("final (1).bin", result.publishedName)
        assertArrayEquals("existing".toByteArray(), Files.readAllBytes(f.root.resolve("final.bin")))
        assertArrayEquals(data, Files.readAllBytes(f.root.resolve("final (1).bin")))
    }

    @Test fun ownerMismatchAndCancelledTombstoneBlockRecreation() = fixture { f ->
        val m = manifest("cancel", byteArrayOf(1, 2, 3)); val receiver = f.receiver()
        receiver.accept("owner", m)
        assertEquals("transfer_owner_mismatch", receiver.append("other", SafIncomingChunk(m.transferId, 0, byteArrayOf(1))).result.failureReason)
        assertEquals("transfer_cancelled", receiver.cancel("owner", m.transferId).result.failureReason)
        assertEquals("transfer_cancelled", f.receiver().accept("owner", m).result.failureReason)
        assertFalse(Files.exists(f.storage.file()))
    }

    @Test fun cancellationBeforeManifestPersistsOwnerScopedTombstoneWithoutAllocation() = fixture { f ->
        val m = manifest("late", "late bytes".toByteArray())
        assertEquals("transfer_cancelled", f.receiver().cancel("owner", m.transferId).result.failureReason)
        val reopened = f.receiver()
        assertEquals("transfer_cancelled", reopened.accept("owner", m).result.failureReason)
        assertEquals("transfer_cancelled", reopened.append("owner", SafIncomingChunk(m.transferId, 0, "late bytes".toByteArray())).result.failureReason)
        assertEquals("transfer_owner_mismatch", reopened.accept("other-owner", m).result.failureReason)
        assertEquals(0, f.storage.allocations)
        assertFalse(Files.exists(f.root.resolve("final.bin")))
        assertFalse(f.journal.load(m.transferId)!!.item.pending)
    }

    @Test fun failedUnknownCancellationPersistenceDoesNotClaimAcknowledgement() = fixture { f ->
        f.journal.fail = true
        assertEquals("transfer_state_persistence_failed", f.receiver().cancel("owner", "late").result.failureReason)
        assertNull(f.journal.load("late"))
        assertEquals(0, f.storage.allocations)
        f.journal.fail = false
        assertEquals("transfer_cancelled", f.receiver().cancel("owner", "late").result.failureReason)
    }

    @Test fun cancelledReconciliationRetriesCleanupBeforeAckAndLeavesFinalUntouched() = fixture { f ->
        val m = manifest("cleanup", "abcdef".toByteArray())
        f.receiver().accept("owner", m)
        Files.write(f.root.resolve("final.bin"), "existing final".toByteArray())
        f.storage.failDelete = true
        assertEquals("pending_cleanup_failed", f.receiver().cancel("owner", m.transferId).result.failureReason)
        assertEquals(1L, f.journal.activeCount())
        assertEquals("pending_cleanup_failed", f.receiver().accept("owner", m).result.failureReason)
        assertEquals("pending_cleanup_failed", f.receiver().append("owner", SafIncomingChunk(m.transferId, 0, byteArrayOf(1))).result.failureReason)
        f.storage.failDelete = false
        assertEquals("transfer_cancelled", f.receiver().accept("owner", m).result.failureReason)
        assertFalse(Files.exists(f.root.resolve(".pending")))
        assertEquals(0L, f.journal.activeCount())
        assertArrayEquals("existing final".toByteArray(), Files.readAllBytes(f.root.resolve("final.bin")))
    }

    @Test fun providerLookupFailureIsNotMistakenForConfirmedAbsence() = fixture { f ->
        val m = manifest("lookup", byteArrayOf(1, 2, 3))
        f.receiver().accept("owner", m)
        f.storage.failResolve = true; f.storage.failAbsence = true
        assertEquals("pending_cleanup_failed", f.receiver().cancel("owner", m.transferId).result.failureReason)
        assertTrue(Files.exists(f.root.resolve(".pending")))
        f.storage.failResolve = false; f.storage.failAbsence = false
        assertEquals("transfer_cancelled", f.receiver().cancel("owner", m.transferId).result.failureReason)
    }

    @Test fun deletionWithLostSettlementCheckpointRecoversWithoutPrematureAck() = fixture { f ->
        val m = manifest("settle", byteArrayOf(1, 2, 3))
        f.receiver().accept("owner", m)
        f.journal.failSettledCancellation = true
        assertEquals("transfer_state_persistence_failed", f.receiver().cancel("owner", m.transferId).result.failureReason)
        assertFalse(Files.exists(f.root.resolve(".pending")))
        assertEquals(1L, f.journal.activeCount())
        f.journal.failSettledCancellation = false
        assertEquals("transfer_cancelled", f.receiver().accept("owner", m).result.failureReason)
        assertEquals(0L, f.journal.activeCount())
    }

    @Test fun wrongFinalHashNeverPublishesAndDuplicateChunkMustMatch() = fixture { f ->
        val m = manifest("hash", "correct".toByteArray()); val receiver = f.receiver(); receiver.accept("owner", m)
        receiver.append("owner", SafIncomingChunk(m.transferId, 0, "bad".toByteArray()))
        assertEquals("conflicting_duplicate", receiver.append("owner", SafIncomingChunk(m.transferId, 0, "BAD".toByteArray())).result.failureReason)
        assertEquals("sha256_mismatch", receiver.append("owner", SafIncomingChunk(m.transferId, 3, "xxxx".toByteArray())).result.failureReason)
        assertTrue(f.storage.current!!.pending)
        assertFalse(Files.exists(f.root.resolve("final.bin")))
    }

    @Test fun historicalReceiptsDoNotExhaustActiveAdmissionOrLoseOldTransferIDs() = fixture { f ->
        repeat(1500) { index ->
            val old = manifest("history-$index", byteArrayOf())
            f.journal.store(DownloadCheckpoint("owner", old,
                PendingDownload("historical:$index", "old:$index", old.relativeName, false),
                0, old.sha256, DownloadPhase.COMPLETED, 1))
        }
        val fresh = manifest("fresh", byteArrayOf(1, 2, 3))
        assertEquals("", f.receiver().accept("owner", fresh).result.failureReason)
        assertEquals(1501, f.journal.records.size)
        val oldReceipt = f.receiver().accept("owner", manifest("history-0", byteArrayOf()))
        assertTrue(oldReceipt.result.complete)
        assertEquals(1501, f.journal.records.size)
    }

    @Test fun tenGiBLimitsUseLongOffsetsWithoutAllocatingPayload() = fixture { f ->
        val m = manifest("large", byteArrayOf()).copy(size = 10L * 1024 * 1024 * 1024)
        assertEquals("", f.receiver().accept("owner", m).result.failureReason)
        assertEquals("invalid_manifest", f.receiver().accept("owner", m.copy(size = m.size + 1)).result.failureReason)
        assertEquals(5L * 1024 * 1024 * 1024 + 1, checkedAddOffset(5L * 1024 * 1024 * 1024, 1))
    }

    private fun manifest(id: String, data: ByteArray) = SafIncomingManifest(id, "final.bin", data.size.toLong(),
        "application/octet-stream", MessageDigest.getInstance("SHA-256").digest(data))
    private fun fixture(body: (Fixture) -> Unit) {
        val root = Files.createTempDirectory("gb-pending-test-")
        try { body(Fixture(root)) } finally { root.toFile().deleteRecursively() }
    }
    private class Fixture(val root: Path) {
        val storage = DiskStorage(root); val journal = Journal()
        fun receiver() = ResumableDownloadsTransfer(storage, journal)
    }
    private class Journal : DownloadJournal {
        val records = mutableMapOf<String, DownloadCheckpoint>(); var fail = false; var failPhase: DownloadPhase? = null; var failSettledCancellation = false
        override fun load(id: String) = records[id]
        override fun store(record: DownloadCheckpoint): Boolean {
            if (fail || record.phase == failPhase || (failSettledCancellation &&
                record.phase == DownloadPhase.CANCELLED && !record.item.pending)) return false
            records[record.manifest.transferId] = record; return true
        }
        override fun all() = records.values.toList()
    }
    private class DiskStorage(val root: Path) : PendingDownloadStorage {
        var current: PendingDownload? = null; var hashBytes = 0L
        var failDelete = false; var failResolve = false; var failAbsence = false; var allocations = 0
        fun file() = root.resolve(if (current?.pending != false) ".pending" else current!!.name)
        override fun allocate(name: String, mimeType: String): PendingDownload {
            allocations++
            Files.createFile(root.resolve(".pending"))
            return PendingDownload("uri:1", "inode:1", name, true).also { current = it }
        }
        override fun resolve(item: PendingDownload) = if (failResolve) null else current?.takeIf { it.identity == item.identity && Files.exists(file()) }
        override fun length(item: PendingDownload) = Files.size(file())
        override fun truncate(item: PendingDownload, length: Long): Boolean {
            RandomAccessFile(file().toFile(), "rw").use { it.setLength(length); it.fd.sync() }; return true
        }
        override fun write(item: PendingDownload, offset: Long, bytes: ByteArray): Boolean {
            RandomAccessFile(file().toFile(), "rw").use { check(it.length() == offset); it.seek(offset); it.write(bytes); it.fd.sync() }; return true
        }
        override fun hashPrefix(item: PendingDownload, length: Long, digest: MessageDigest): Boolean {
            hashBytes += length
            return Files.newInputStream(file()).use { SafCheckpointHashing.updatePrefix(it, length, digest) }
        }
        override fun matches(item: PendingDownload, offset: Long, bytes: ByteArray): Boolean = RandomAccessFile(file().toFile(), "r").use {
            it.seek(offset); val actual = ByteArray(bytes.size); it.readFully(actual); actual.contentEquals(bytes)
        }
        override fun publish(item: PendingDownload): PendingDownload {
            val name = if (Files.exists(root.resolve(item.name))) "final (1).bin" else item.name
            Files.move(file(), root.resolve(name)) // No REPLACE_EXISTING: real no-clobber fixture.
            return item.copy(name = name, pending = false).also { current = it }
        }
        override fun deletePending(item: PendingDownload): Boolean = !failDelete && current?.pending == true && Files.deleteIfExists(file())
        override fun isAbsent(item: PendingDownload): Boolean = !failAbsence && !Files.exists(file())
    }
}
