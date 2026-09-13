package com.xopmc.galaxybridge.transport

import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ResumableSafTransferTest {
    @Test
    fun resumesOnlyAfterRehashingThePersistedConfirmedPrefix() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = ByteArray(1_500_000) { (it % 251).toByte() }
        val manifest = manifest("resume", "archive.bin", bytes)

        val first = ResumableSafTransfer(storage, journal, nowMillis = { 1_000 })
        assertEquals(0, first.accept(manifest).confirmedOffset)
        assertEquals(
            1_048_576,
            first.append(SafIncomingChunk("resume", 0, bytes.copyOfRange(0, 1_048_576))).confirmedOffset,
        )

        val recreated = ResumableSafTransfer(storage, journal, nowMillis = { 2_000 })
        val resumed = recreated.accept(manifest)

        assertEquals(1_048_576, resumed.confirmedOffset)
        assertFalse(resumed.complete)
        assertEquals(1, storage.documents.size)
        assertEquals(0, storage.privateStagingBytes)
        assertEquals(1_048_576, storage.prefixBytesRead)
    }

    @Test
    fun rejectsSameLengthPrefixMutationAfterReceiverRecreation() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "abcdefgh".toByteArray()
        val manifest = manifest("mutated-prefix", "archive.bin", bytes)
        val first = ResumableSafTransfer(storage, journal)
        first.accept(manifest)
        first.append(SafIncomingChunk("mutated-prefix", 0, bytes.copyOfRange(0, 4)))
        storage.mutateByte(0, 'z'.code.toByte())

        val recovered = ResumableSafTransfer(storage, journal).accept(manifest)

        assertEquals("checkpoint_prefix_mismatch", recovered.failureReason)
        assertEquals(0, recovered.confirmedOffset)
        assertArrayEquals("zbcd".toByteArray(), storage.onlyDocumentBytes())
    }

    @Test
    fun rejectsDocumentShorterThanPersistedCheckpoint() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "abcdefgh".toByteArray()
        val manifest = manifest("short-prefix", "archive.bin", bytes)
        val first = ResumableSafTransfer(storage, journal)
        first.accept(manifest)
        first.append(SafIncomingChunk("short-prefix", 0, bytes.copyOfRange(0, 6)))
        storage.resizeOnlyDocument(3)

        val recovered = ResumableSafTransfer(storage, journal).accept(manifest)

        assertEquals("checkpoint_prefix_mismatch", recovered.failureReason)
        assertEquals(0, recovered.confirmedOffset)
        assertEquals(3, storage.onlyDocumentBytes().size)
    }

    @Test
    fun truncatesOnlyUncommittedTailAfterVerifiedRecovery() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "abcdefgh".toByteArray()
        val manifest = manifest("tail", "archive.bin", bytes)
        val first = ResumableSafTransfer(storage, journal)
        first.accept(manifest)
        first.append(SafIncomingChunk("tail", 0, bytes.copyOfRange(0, 4)))
        storage.appendUncommitted("XX".toByteArray())

        val recovered = ResumableSafTransfer(storage, journal).accept(manifest)

        assertEquals("", recovered.failureReason)
        assertEquals(4, recovered.confirmedOffset)
        assertArrayEquals("abcd".toByteArray(), storage.onlyDocumentBytes())
    }

    @Test
    fun rejectsOffsetMismatchUsingActualTemporaryDocumentLength() {
        val storage = FakeSafStorage()
        val transfer = ResumableSafTransfer(storage, MemorySafTransferJournal())
        val bytes = "abcdefgh".toByteArray()
        transfer.accept(manifest("offset", "note.txt", bytes))
        transfer.append(SafIncomingChunk("offset", 0, bytes.copyOfRange(0, 4)))

        val result = transfer.append(SafIncomingChunk("offset", 3, bytes.copyOfRange(4, 8)))

        assertEquals("unexpected_offset", result.failureReason)
        assertEquals(4, result.confirmedOffset)
        assertArrayEquals(bytes.copyOfRange(0, 4), storage.onlyDocumentBytes())
    }

    @Test
    fun partialWriteDoesNotAdvanceConfirmedOffsetAndIsReconciledBeforeRetry() {
        val storage = FakeSafStorage(partialWriteBytes = 2)
        val journal = MemorySafTransferJournal()
        val bytes = "abcdefgh".toByteArray()
        val manifest = manifest("partial-write", "note.txt", bytes)
        val transfer = ResumableSafTransfer(storage, journal)
        transfer.accept(manifest)

        val failed = transfer.append(SafIncomingChunk("partial-write", 0, bytes.copyOfRange(0, 4)))

        assertEquals("provider_no_resumable_write", failed.failureReason)
        assertEquals(0, failed.confirmedOffset)
        assertArrayEquals("ab".toByteArray(), storage.onlyDocumentBytes())

        storage.partialWriteBytes = null
        val retried = transfer.append(SafIncomingChunk("partial-write", 0, bytes.copyOfRange(0, 4)))
        assertEquals("", retried.failureReason)
        assertEquals(4, retried.confirmedOffset)
        assertArrayEquals("abcd".toByteArray(), storage.onlyDocumentBytes())
    }

    @Test
    fun journalPersistenceFailureRetainsPreviousCheckpointAndRequiresRecovery() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "abcdefgh".toByteArray()
        val manifest = manifest("persist", "note.txt", bytes)
        val transfer = ResumableSafTransfer(storage, journal)
        transfer.accept(manifest)
        journal.failNextStore = true

        val failed = transfer.append(SafIncomingChunk("persist", 0, bytes.copyOfRange(0, 4)))

        assertEquals("transfer_state_persistence_failed", failed.failureReason)
        assertEquals(0, failed.confirmedOffset)
        assertArrayEquals("abcd".toByteArray(), storage.onlyDocumentBytes())

        val retried = transfer.append(SafIncomingChunk("persist", 0, bytes.copyOfRange(0, 4)))
        assertEquals("", retried.failureReason)
        assertEquals(4, retried.confirmedOffset)
        assertArrayEquals("abcd".toByteArray(), storage.onlyDocumentBytes())
    }

    @Test
    fun exactDuplicateAfterLostAckReconcilesButConflictingDuplicateFails() {
        val storage = FakeSafStorage()
        val transfer = ResumableSafTransfer(storage, MemorySafTransferJournal())
        val bytes = "abcdefgh".toByteArray()
        transfer.accept(manifest("duplicate", "note.txt", bytes))
        val firstChunk = bytes.copyOfRange(0, 4)
        assertEquals(4, transfer.append(SafIncomingChunk("duplicate", 0, firstChunk)).confirmedOffset)

        val exact = transfer.append(SafIncomingChunk("duplicate", 0, firstChunk))
        val conflicting = transfer.append(SafIncomingChunk("duplicate", 0, "abcz".toByteArray()))

        assertEquals("", exact.failureReason)
        assertEquals(4, exact.confirmedOffset)
        assertEquals("conflicting_duplicate", conflicting.failureReason)
        assertEquals(4, conflicting.confirmedOffset)
        assertArrayEquals("abcd".toByteArray(), storage.onlyDocumentBytes())
    }

    @Test
    fun concurrentExactAppendsSerializeToOneWriteAndTwoCommittedAcks() {
        val storage = FakeSafStorage()
        val transfer = ResumableSafTransfer(storage, MemorySafTransferJournal())
        val bytes = "abcdefgh".toByteArray()
        transfer.accept(manifest("concurrent", "note.txt", bytes))
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val futures = List(2) {
                executor.submit<SafTransferResult> {
                    start.await()
                    transfer.append(SafIncomingChunk("concurrent", 0, bytes.copyOfRange(0, 4)))
                }
            }
            start.countDown()
            val results = futures.map { it.get(5, TimeUnit.SECONDS) }

            assertTrue(results.all { it.failureReason.isEmpty() && it.confirmedOffset == 4L })
            assertEquals(listOf(0L), storage.writeOffsets)
            assertArrayEquals("abcd".toByteArray(), storage.onlyDocumentBytes())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun corruptCompletedDocumentIsTruncatedSoSenderCanRestart() {
        val storage = FakeSafStorage(corruptReads = true)
        val journal = MemorySafTransferJournal()
        val transfer = ResumableSafTransfer(storage, journal)
        val bytes = "expected payload".toByteArray()
        transfer.accept(manifest("bad-hash", "payload.bin", bytes))

        val result = transfer.append(SafIncomingChunk("bad-hash", 0, bytes))

        assertEquals("sha256_mismatch", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertEquals(0, storage.onlyDocumentBytes().size)
        assertNotNull(journal.load("bad-hash"))
    }

    @Test
    fun failedResetCheckpointStorePreservesFullDocumentAndPreviousCheckpointForRestart() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "stored payload".toByteArray()
        val wrongHashManifest = manifest("reset-store-failure", "payload.bin", bytes).copy(
            sha256 = ByteArray(32) { 0x5a },
        )
        val transfer = ResumableSafTransfer(storage, journal)
        transfer.accept(wrongHashManifest)
        journal.failStoreWhen = { it.confirmedOffset == 0L }

        val failed = transfer.append(SafIncomingChunk("reset-store-failure", 0, bytes))

        assertEquals("transfer_state_persistence_failed", failed.failureReason)
        assertEquals(bytes.size.toLong(), failed.confirmedOffset)
        assertArrayEquals(bytes, storage.onlyDocumentBytes())
        assertEquals(bytes.size.toLong(), journal.load("reset-store-failure")?.confirmedOffset)

        journal.failStoreWhen = null
        val restarted = ResumableSafTransfer(storage, journal).accept(wrongHashManifest)
        assertEquals("sha256_mismatch", restarted.failureReason)
        assertEquals(0, restarted.confirmedOffset)
        assertEquals(0, storage.onlyDocumentBytes().size)
        assertEquals(0L, journal.load("reset-store-failure")?.confirmedOffset)
    }

    @Test
    fun renameDuringRecoveryPrefixReadPreservesUncommittedTailAndJournal() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "abcdefgh".toByteArray()
        val manifest = manifest("rename-during-prefix", "final.bin", bytes)
        val first = ResumableSafTransfer(storage, journal)
        first.accept(manifest)
        first.append(SafIncomingChunk("rename-during-prefix", 0, bytes.copyOfRange(0, 4)))
        storage.appendUncommitted("XX".toByteArray())
        storage.renameDuringPrefixReadTo = "final.bin"

        val recovered = ResumableSafTransfer(storage, journal).accept(manifest)

        assertEquals("transfer_document_ownership_mismatch", recovered.failureReason)
        assertEquals(0, recovered.confirmedOffset)
        assertArrayEquals("abcdXX".toByteArray(), storage.onlyDocumentBytes())
        assertEquals(setOf("final.bin"), storage.displayNames())
        assertNotNull(journal.load("rename-during-prefix"))
    }

    @Test
    fun renameDuringFinalHashPreventsTruncateOrPublication() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "complete payload".toByteArray()
        val transfer = ResumableSafTransfer(storage, journal)
        transfer.accept(manifest("rename-during-final-hash", "final.bin", bytes))
        storage.renameDuringFullHashTo = "someone-else.bin"

        val result = transfer.append(SafIncomingChunk("rename-during-final-hash", 0, bytes))

        assertEquals("transfer_document_ownership_mismatch", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertArrayEquals(bytes, storage.onlyDocumentBytes())
        assertEquals(setOf("someone-else.bin"), storage.displayNames())
        assertTrue(storage.renamedTo.isEmpty())
        assertNotNull(journal.load("rename-during-final-hash"))
    }

    @Test
    fun renameAfterDurableResetTransitionPreventsTruncation() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "stored payload".toByteArray()
        val wrongHashManifest = manifest("rename-after-reset-store", "final.bin", bytes).copy(
            sha256 = ByteArray(32) { 0x33 },
        )
        val transfer = ResumableSafTransfer(storage, journal)
        transfer.accept(wrongHashManifest)
        journal.afterStore = { record ->
            if (record.confirmedOffset == 0L) storage.renameOnlyDocument("someone-else.bin")
        }

        val result = transfer.append(SafIncomingChunk("rename-after-reset-store", 0, bytes))

        assertEquals("transfer_document_ownership_mismatch", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertArrayEquals(bytes, storage.onlyDocumentBytes())
        assertEquals(setOf("someone-else.bin"), storage.displayNames())
        assertEquals(0L, journal.load("rename-after-reset-store")?.confirmedOffset)
    }

    @Test
    fun streamsHashThenRenamesTemporaryDocumentToRequestedName() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val transfer = ResumableSafTransfer(storage, journal)
        val bytes = "complete payload".toByteArray()
        transfer.accept(manifest("complete", "holiday.jpg", bytes, "image/jpeg"))

        val result = transfer.append(SafIncomingChunk("complete", 0, bytes))

        assertTrue(result.complete)
        assertEquals("", result.failureReason)
        assertEquals("holiday.jpg", storage.documents.values.single().displayName)
        assertEquals(listOf("holiday.jpg"), storage.renamedTo)
        assertEquals(null, journal.load("complete"))
    }

    @Test
    fun unsupportedProviderFailsExplicitlyAndDoesNotLeaveAFalseResumeRecord() {
        val storage = FakeSafStorage(resumable = false)
        val journal = MemorySafTransferJournal()
        val transfer = ResumableSafTransfer(storage, journal)
        val bytes = "payload".toByteArray()

        val result = transfer.accept(manifest("unsupported", "payload.bin", bytes))

        assertEquals("provider_no_resumable_write", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertFalse(result.complete)
        assertTrue(storage.documents.isEmpty())
        assertEquals(null, journal.load("unsupported"))
    }

    @Test
    fun acceptsTenGiBManifestAndWritesOnlyIntoDestinationTemporaryDocument() {
        val storage = FakeSafStorage()
        val transfer = ResumableSafTransfer(storage, MemorySafTransferJournal())
        val tenGiB = 10L * 1024 * 1024 * 1024
        val manifest = SafIncomingManifest(
            transferId = "ten-gib",
            relativeName = "backup.bin",
            size = tenGiB,
            mimeType = "application/octet-stream",
            sha256 = ByteArray(32) { 7 },
        )
        val chunk = ByteArray(1_048_576) { 3 }

        assertEquals(0, transfer.accept(manifest).confirmedOffset)
        val result = transfer.append(SafIncomingChunk("ten-gib", 0, chunk))

        assertEquals(1_048_576, result.confirmedOffset)
        assertEquals(1_048_576, storage.totalDocumentBytes())
        assertEquals(0, storage.privateStagingBytes)
        assertEquals(1, storage.writeOffsets.size)
    }

    @Test
    fun staleOwnedTemporaryDocumentsAreRemovedAfterSevenDaysAndRevokeRemovesOwnedActive() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        var now = 0L
        val transfer = ResumableSafTransfer(storage, journal, nowMillis = { now })
        transfer.accept(manifest("stale", "stale.bin", "stale".toByteArray()))
        now = EIGHT_DAYS
        transfer.accept(manifest("active", "active.bin", "active".toByteArray()))

        transfer.cleanup(EIGHT_DAYS)

        assertEquals(null, journal.load("stale"))
        assertNotNull(journal.load("active"))
        assertEquals(1, storage.documents.size)

        transfer.revoke()

        assertTrue(storage.documents.isEmpty())
        assertTrue(journal.all().isEmpty())
    }

    @Test
    fun cleanupAndRevokePreservePrefixLookalikeAndRenamedFinalSentinels() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        var now = 0L
        val transfer = ResumableSafTransfer(storage, journal, nowMillis = { now })
        val bytes = "payload".toByteArray()
        transfer.accept(manifest("renamed", "final.bin", bytes))
        storage.renameOnlyDocument("final.bin")
        storage.addDocument("lookalike", ".galaxybridge-not-owned.part", "sentinel".toByteArray(), 0)
        now = EIGHT_DAYS

        transfer.cleanup(now)
        transfer.revoke()

        assertEquals(setOf("final.bin", ".galaxybridge-not-owned.part"), storage.displayNames())
        assertNotNull(journal.load("renamed"))
    }

    @Test
    fun cleanupPreservesJournalTargetWhoseExpectedTemporaryNameNoLongerMatches() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val transfer = ResumableSafTransfer(storage, journal, nowMillis = { 0 })
        val bytes = "payload".toByteArray()
        transfer.accept(manifest("ownership", "final.bin", bytes))
        storage.renameOnlyDocument("someone-else.bin")

        transfer.cleanup(EIGHT_DAYS)

        assertEquals(setOf("someone-else.bin"), storage.displayNames())
        assertNotNull(journal.load("ownership"))
    }

    @Test
    fun appendRejectsDocumentRenamedAfterAcceptWithoutWritingOrDeletingIt() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val bytes = "payload".toByteArray()
        val transfer = ResumableSafTransfer(storage, journal)
        transfer.accept(manifest("renamed-before-write", "final.bin", bytes))
        storage.renameOnlyDocument("final.bin")

        val result = transfer.append(SafIncomingChunk("renamed-before-write", 0, bytes))

        assertEquals("transfer_document_ownership_mismatch", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertEquals(setOf("final.bin"), storage.displayNames())
        assertTrue(storage.writeOffsets.isEmpty())
        assertNotNull(journal.load("renamed-before-write"))
    }

    @Test
    fun providerAdjustedTextTemporaryNameIsPersistedAndResumesAfterRestart() {
        val adjustedName = ".galaxybridge-provider-adjusted.part.txt"
        val storage = FakeSafStorage(createdDisplayNameOverride = adjustedName)
        val journal = MemorySafTransferJournal()
        val bytes = "abcdefgh".toByteArray()
        val incoming = manifest("adjusted-name", "final.txt", bytes, "text/plain")
        val first = ResumableSafTransfer(storage, journal)

        val accepted = first.accept(incoming)
        val firstChunk = first.append(SafIncomingChunk("adjusted-name", 0, bytes.copyOfRange(0, 4)))

        assertEquals("", accepted.failureReason)
        assertEquals(4, firstChunk.confirmedOffset)
        assertEquals(adjustedName, journal.load("adjusted-name")?.temporaryName)
        assertEquals(listOf("text/plain"), storage.createdMimeTypes)

        val restarted = ResumableSafTransfer(storage, journal).accept(incoming)
        assertEquals("", restarted.failureReason)
        assertEquals(4, restarted.confirmedOffset)

        val completed = ResumableSafTransfer(storage, journal).append(
            SafIncomingChunk("adjusted-name", 4, bytes.copyOfRange(4, bytes.size)),
        )
        assertTrue(completed.complete)
        assertEquals(setOf("final.txt"), storage.displayNames())
        assertEquals("text/plain", storage.onlyDocumentMimeType())
    }

    @Test
    fun providerAdjustedImageAndCollisionNamesPreserveMimeAndFinalName() {
        val cases = listOf(
            Triple("image/png", ".galaxybridge-image.part.png", "photo.png"),
            Triple("application/x-galaxybridge-blob", ".galaxybridge-collision (1).part", "archive.gbb"),
            Triple("", ".galaxybridge-unknown.part.bin", "unknown.bin"),
        )

        cases.forEachIndexed { index, (mimeType, adjustedName, finalName) ->
            val storage = FakeSafStorage(createdDisplayNameOverride = adjustedName)
            val journal = MemorySafTransferJournal()
            val bytes = "payload-$index".toByteArray()
            val transferId = "mime-$index"
            val transfer = ResumableSafTransfer(storage, journal)

            assertEquals("", transfer.accept(manifest(transferId, finalName, bytes, mimeType)).failureReason)
            assertEquals(adjustedName, journal.load(transferId)?.temporaryName)
            val expectedMime = if (mimeType.isBlank()) "application/octet-stream" else mimeType
            assertEquals(listOf(expectedMime), storage.createdMimeTypes)

            val completed = transfer.append(SafIncomingChunk(transferId, 0, bytes))
            assertTrue(completed.complete)
            assertEquals(setOf(finalName), storage.displayNames())
            assertEquals(expectedMime, storage.onlyDocumentMimeType())
        }
    }

    @Test
    fun providerAdjustedTemporaryRenamedExternallyIsNeverWrittenDeletedOrAdopted() {
        val adjustedName = ".galaxybridge-adjusted.part.txt"
        val storage = FakeSafStorage(createdDisplayNameOverride = adjustedName)
        val journal = MemorySafTransferJournal()
        val bytes = "payload".toByteArray()
        val transfer = ResumableSafTransfer(storage, journal, nowMillis = { 0 })

        assertEquals("", transfer.accept(manifest("adjusted-renamed", "final.txt", bytes, "text/plain")).failureReason)
        storage.renameOnlyDocument("final.txt")

        val append = transfer.append(SafIncomingChunk("adjusted-renamed", 0, bytes))
        transfer.cleanup(EIGHT_DAYS)
        transfer.revoke()

        assertEquals("transfer_document_ownership_mismatch", append.failureReason)
        assertTrue(storage.writeOffsets.isEmpty())
        assertEquals(setOf("final.txt"), storage.displayNames())
        assertNotNull(journal.load("adjusted-renamed"))
    }

    @Test
    fun providerReturningRequestedFinalNameIsRejectedBeforeOwnershipIsRecorded() {
        val storage = FakeSafStorage(createdDisplayNameOverride = "final.txt")
        val journal = MemorySafTransferJournal()
        val bytes = "payload".toByteArray()

        val result = ResumableSafTransfer(storage, journal).accept(
            manifest("final-as-temporary", "final.txt", bytes, "text/plain"),
        )

        assertEquals("temporary_name_unavailable", result.failureReason)
        assertTrue(storage.documents.isEmpty())
        assertTrue(journal.all().isEmpty())
    }

    @Test
    fun rejectsTraversalAndInvalidMimeBeforeCreatingDestinationDocument() {
        val storage = FakeSafStorage()
        val transfer = ResumableSafTransfer(storage, MemorySafTransferJournal())
        val hash = ByteArray(32)

        val traversal = transfer.accept(
            SafIncomingManifest("path", "../private.txt", 1, "text/plain", hash),
        )
        val invalidMime = transfer.accept(
            SafIncomingManifest("mime", "safe.txt", 1, "text/plain\nimage/png", hash),
        )

        assertEquals("invalid_name", traversal.failureReason)
        assertEquals("invalid_mime_type", invalidMime.failureReason)
        assertTrue(storage.documents.isEmpty())
    }

    @Test
    fun persistentRecordCodecRoundTripsDocumentUriAndLongSize() {
        val record = SafTransferRecord(
            transferId = "transfer-1",
            treeId = "content://provider/tree/downloads",
            documentId = "content://provider/tree/downloads/document/.galaxybridge-1.part",
            temporaryName = ".galaxybridge-1.part.txt",
            relativeName = "backup 10 GiB.bin",
            size = 10L * 1024 * 1024 * 1024,
            mimeType = "application/octet-stream",
            sha256 = ByteArray(32) { it.toByte() },
            updatedAtMillis = 42_000,
            confirmedOffset = 5L * 1024 * 1024 * 1024,
            prefixSha256 = ByteArray(32) { (31 - it).toByte() },
        )

        val decoded = SafTransferRecordCodec.decode(SafTransferRecordCodec.encode(record))

        assertNotNull(decoded)
        assertEquals(record.transferId, decoded!!.transferId)
        assertEquals(record.treeId, decoded.treeId)
        assertEquals(record.documentId, decoded.documentId)
        assertEquals(record.temporaryName, decoded.temporaryName)
        assertEquals(record.relativeName, decoded.relativeName)
        assertEquals(record.size, decoded.size)
        assertArrayEquals(record.sha256, decoded.sha256)
        assertEquals(record.updatedAtMillis, decoded.updatedAtMillis)
        assertEquals(record.confirmedOffset, decoded.confirmedOffset)
        assertArrayEquals(record.prefixSha256, decoded.prefixSha256)
        val version = java.io.DataInputStream(
            java.io.ByteArrayInputStream(Base64.getUrlDecoder().decode(SafTransferRecordCodec.encode(record))),
        ).use { it.readInt() }
        assertEquals(2, version)
    }

    @Test
    fun versionTwoRecordWhoseTemporaryNameEqualsFinalNameIsInvalid() {
        val record = SafTransferRecord(
            transferId = "unsafe-owner",
            treeId = "content://provider/tree/downloads",
            documentId = "content://provider/document/unsafe-owner",
            temporaryName = "final.txt",
            relativeName = "final.txt",
            size = 0,
            mimeType = "text/plain",
            sha256 = sha256(ByteArray(0)),
            updatedAtMillis = 42_000,
        )

        assertNull(SafTransferRecordCodec.decode(versionTwoRecord(record)))
    }

    @Test
    fun legacyRecordFailsClosedWithoutAdoptingLengthDeletingDataOrCreatingReplacement() {
        val storage = FakeSafStorage()
        val bytes = "abcdefgh".toByteArray()
        val manifest = manifest("legacy", "archive.bin", bytes)
        val documentId = "document://legacy"
        storage.addDocument(documentId, ".galaxybridge-legacy.part", bytes.copyOfRange(0, 4), 0)
        val legacy = SafTransferRecordCodec.decode(
            legacyRecord(
                transferId = "legacy",
                treeId = storage.selectedTreeId,
                documentId = documentId,
                temporaryName = ".galaxybridge-legacy.part",
                relativeName = "archive.bin",
                size = bytes.size.toLong(),
                sha256 = sha256(bytes),
            ),
        )
        assertNotNull(legacy)
        val journal = MemorySafTransferJournal(listOf(legacy!!))

        val result = ResumableSafTransfer(storage, journal).accept(manifest)

        assertEquals("checkpoint_proof_unavailable", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertEquals(1, storage.documents.size)
        assertArrayEquals("abcd".toByteArray(), storage.onlyDocumentBytes())
        assertNotNull(journal.load("legacy"))
    }

    @Test
    fun invalidRecordCodecFailsClosed() {
        assertNull(SafTransferRecordCodec.decode("not-base64"))
        val invalidVersion = java.io.ByteArrayOutputStream().use { buffer ->
            java.io.DataOutputStream(buffer).use { it.writeInt(99) }
            Base64.getUrlEncoder().withoutPadding().encodeToString(buffer.toByteArray())
        }
        assertNull(SafTransferRecordCodec.decode(invalidVersion))
    }

    @Test
    fun invalidPersistedEntryBlocksReplacementDocumentCreation() {
        val storage = FakeSafStorage()
        val journal = object : SafTransferJournal {
            override fun load(transferId: String): SafTransferRecord? = null
            override fun store(record: SafTransferRecord): Boolean = error("must not store")
            override fun remove(transferId: String) = error("must not remove")
            override fun all(): List<SafTransferRecord> = emptyList()
            override fun contains(transferId: String): Boolean = transferId == "invalid-state"
        }
        val bytes = "payload".toByteArray()

        val result = ResumableSafTransfer(storage, journal).accept(manifest("invalid-state", "payload.bin", bytes))

        assertEquals("transfer_state_invalid", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertTrue(storage.documents.isEmpty())
    }

    @Test
    fun activeDigestStateIsBoundedBeforeAnotherDocumentIsCreated() {
        val storage = FakeSafStorage()
        val journal = MemorySafTransferJournal()
        val transfer = ResumableSafTransfer(storage, journal)
        repeat(ResumableSafTransfer.MAX_ACTIVE_TRANSFERS) { index ->
            val bytes = "payload-$index".toByteArray()
            assertEquals("", transfer.accept(manifest("active-$index", "payload-$index.bin", bytes)).failureReason)
        }
        val overflowBytes = "overflow".toByteArray()

        val overflow = transfer.accept(manifest("active-overflow", "overflow.bin", overflowBytes))

        assertEquals("too_many_active_transfers", overflow.failureReason)
        assertEquals(ResumableSafTransfer.MAX_ACTIVE_TRANSFERS, storage.documents.size)
    }

    @Test
    fun offsetArithmeticSupportsMoreThanFourGiBAndRejectsOverflow() {
        val fiveGiB = 5L * 1024 * 1024 * 1024

        assertEquals(fiveGiB + 1_048_576L, checkedAddOffset(fiveGiB, 1_048_576))
        assertNull(checkedAddOffset(Long.MAX_VALUE, 1))
        assertNull(checkedAddOffset(-1, 1))
    }

    @Test
    fun nonCloneableSha256ProviderFailsBeforeCreatingOrWritingDocument() {
        val storage = FakeSafStorage()
        val bytes = "payload".toByteArray()
        val transfer = ResumableSafTransfer(
            storage = storage,
            journal = MemorySafTransferJournal(),
            digestFactory = { NonCloneableDigest() },
        )

        val result = transfer.accept(manifest("no-clone", "payload.bin", bytes))

        assertEquals("checkpoint_proof_unavailable", result.failureReason)
        assertEquals(0, result.confirmedOffset)
        assertTrue(storage.documents.isEmpty())
    }

    @Test
    fun checkpointHashingReadsOnlyTheRequestedPrefixWithBoundedBuffer() {
        val bytes = ByteArray(1_500_000) { (it % 251).toByte() }
        val input = TrackingInputStream(bytes)
        val digest = MessageDigest.getInstance("SHA-256")

        val updated = SafCheckpointHashing.updatePrefix(input, 1_048_579, digest)

        assertTrue(updated)
        assertEquals(1_048_579, input.totalBytesRead)
        assertTrue(input.maxRequestedBytes <= 64 * 1024)
        assertArrayEquals(sha256(bytes.copyOfRange(0, 1_048_579)), digest.digest())
    }

    @Test
    fun checkpointHashingRejectsShortStreamWithoutPaddingProof() {
        val digest = MessageDigest.getInstance("SHA-256")

        assertFalse(SafCheckpointHashing.updatePrefix(java.io.ByteArrayInputStream("abc".toByteArray()), 4, digest))
    }

    @Test
    fun companionReceiverInitializationRunsOnceOnIoBeforeRequestsCanBeServed() {
        val callerThreadName = Thread.currentThread().name
        val events = mutableListOf<String>()
        var initializationCount = 0
        val startup = CompanionReceiverStartup {
            initializationCount++
            events += "receiver_maintenance"
            Thread.currentThread().name
        }
        assertTrue(events.isEmpty())

        val receiverThreadName = runBlocking { startup.initializeOnIo() }
        events += "serve_request"
        val secondLookupThreadName = runBlocking { startup.initializeOnIo() }

        assertNotEquals(callerThreadName, receiverThreadName)
        assertEquals(receiverThreadName, secondLookupThreadName)
        assertEquals(1, initializationCount)
        assertEquals(listOf("receiver_maintenance", "serve_request"), events)
    }

    private fun manifest(
        id: String,
        name: String,
        bytes: ByteArray,
        mimeType: String = "application/octet-stream",
    ) = SafIncomingManifest(id, name, bytes.size.toLong(), mimeType, sha256(bytes))

    private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    private fun legacyRecord(
        transferId: String,
        treeId: String,
        documentId: String,
        temporaryName: String,
        relativeName: String,
        size: Long,
        sha256: ByteArray,
    ): String = java.io.ByteArrayOutputStream().use { buffer ->
        java.io.DataOutputStream(buffer).use { output ->
            output.writeInt(1)
            output.writeUTF(transferId)
            output.writeUTF(treeId)
            output.writeUTF(documentId)
            output.writeUTF(temporaryName)
            output.writeUTF(relativeName)
            output.writeLong(size)
            output.writeUTF("application/octet-stream")
            output.writeInt(sha256.size)
            output.write(sha256)
            output.writeLong(42_000)
        }
        Base64.getUrlEncoder().withoutPadding().encodeToString(buffer.toByteArray())
    }

    private fun versionTwoRecord(record: SafTransferRecord): String = java.io.ByteArrayOutputStream().use { buffer ->
        java.io.DataOutputStream(buffer).use { output ->
            output.writeInt(2)
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
            val prefixSha256 = requireNotNull(record.prefixSha256)
            output.writeInt(prefixSha256.size)
            output.write(prefixSha256)
        }
        Base64.getUrlEncoder().withoutPadding().encodeToString(buffer.toByteArray())
    }

    private class MemorySafTransferJournal(initial: List<SafTransferRecord> = emptyList()) : SafTransferJournal {
        private val records = linkedMapOf<String, SafTransferRecord>().apply {
            initial.forEach { put(it.transferId, it) }
        }
        var failNextStore = false
        var failStoreWhen: ((SafTransferRecord) -> Boolean)? = null
        var afterStore: ((SafTransferRecord) -> Unit)? = null

        override fun load(transferId: String): SafTransferRecord? = records[transferId]

        override fun store(record: SafTransferRecord): Boolean {
            if (failNextStore) {
                failNextStore = false
                return false
            }
            if (failStoreWhen?.invoke(record) == true) return false
            records[record.transferId] = record
            afterStore?.invoke(record)
            return true
        }

        override fun remove(transferId: String) {
            records.remove(transferId)
        }

        override fun all(): List<SafTransferRecord> = records.values.toList()
    }

    private class FakeSafStorage(
        private val resumable: Boolean = true,
        private val corruptReads: Boolean = false,
        var partialWriteBytes: Int? = null,
        private val createdDisplayNameOverride: String? = null,
    ) : SafTransferStorage {
        override val selectedTreeId: String = "tree://downloads"
        val documents = linkedMapOf<String, StoredDocument>()
        val renamedTo = mutableListOf<String>()
        val writeOffsets = mutableListOf<Long>()
        val createdMimeTypes = mutableListOf<String>()
        val privateStagingBytes: Long = 0
        var prefixBytesRead: Long = 0
        var renameDuringPrefixReadTo: String? = null
        var renameDuringFullHashTo: String? = null
        private var nextId = 0

        override fun createTemporary(treeId: String, mimeType: String, displayName: String): SafDocument {
            val id = "document://${++nextId}"
            val actualDisplayName = createdDisplayNameOverride ?: displayName
            createdMimeTypes += mimeType
            documents[id] = StoredDocument(actualDisplayName, ByteArray(0), 0, mimeType)
            return SafDocument(id, actualDisplayName)
        }

        override fun resolve(documentId: String): SafDocument? = documents[documentId]?.let {
            SafDocument(documentId, it.displayName)
        }

        override fun supportsResumableWrite(document: SafDocument): Boolean = resumable

        override fun length(document: SafDocument): Long? = documents[document.id]?.bytes?.size?.toLong()

        override fun truncate(document: SafDocument, length: Long): Boolean {
            if (!resumable || length > Int.MAX_VALUE) return false
            val stored = documents[document.id] ?: return false
            stored.bytes = stored.bytes.copyOf(length.toInt())
            return true
        }

        override fun write(document: SafDocument, offset: Long, bytes: ByteArray): Boolean {
            if (!resumable || offset > Int.MAX_VALUE) return false
            val stored = documents[document.id] ?: return false
            if (stored.bytes.size.toLong() != offset) return false
            writeOffsets += offset
            val accepted = partialWriteBytes?.coerceIn(0, bytes.size) ?: bytes.size
            stored.bytes += bytes.copyOf(accepted)
            return accepted == bytes.size
        }

        override fun updateSha256Prefix(document: SafDocument, length: Long, digest: MessageDigest): Boolean {
            val bytes = documents[document.id]?.bytes ?: return false
            if (length < 0 || length > bytes.size) return false
            digest.update(bytes, 0, length.toInt())
            prefixBytesRead += length
            renameDuringPrefixReadTo?.let { displayName ->
                documents[document.id]?.displayName = displayName
                renameDuringPrefixReadTo = null
            }
            return true
        }

        override fun matches(document: SafDocument, offset: Long, bytes: ByteArray): Boolean {
            val stored = documents[document.id]?.bytes ?: return false
            val endOffset = checkedAddOffset(offset, bytes.size) ?: return false
            if (endOffset > stored.size) return false
            return stored.copyOfRange(offset.toInt(), endOffset.toInt()).contentEquals(bytes)
        }

        override fun sha256(document: SafDocument): ByteArray? {
            val bytes = documents[document.id]?.bytes ?: return null
            val hash = MessageDigest.getInstance("SHA-256").digest(
                if (corruptReads && bytes.isNotEmpty()) bytes.copyOf().also { it[0] = (it[0] + 1).toByte() } else bytes,
            )
            renameDuringFullHashTo?.let { displayName ->
                documents[document.id]?.displayName = displayName
                renameDuringFullHashTo = null
            }
            return hash
        }

        override fun rename(document: SafDocument, displayName: String): SafDocument? {
            val stored = documents[document.id] ?: return null
            stored.displayName = displayName
            renamedTo += displayName
            return SafDocument(document.id, displayName)
        }

        override fun delete(document: SafDocument): Boolean = documents.remove(document.id) != null

        override fun finalDocumentExists(treeId: String, displayName: String): Boolean =
            documents.values.any { it.displayName == displayName }

        fun onlyDocumentBytes(): ByteArray = documents.values.single().bytes

        fun mutateByte(index: Int, value: Byte) {
            documents.values.single().bytes[index] = value
        }

        fun resizeOnlyDocument(length: Int) {
            val stored = documents.values.single()
            stored.bytes = stored.bytes.copyOf(length)
        }

        fun appendUncommitted(bytes: ByteArray) {
            val stored = documents.values.single()
            stored.bytes += bytes
        }

        fun renameOnlyDocument(displayName: String) {
            documents.values.single().displayName = displayName
        }

        fun addDocument(id: String, displayName: String, bytes: ByteArray, lastModifiedMillis: Long) {
            documents[id] = StoredDocument(displayName, bytes.copyOf(), lastModifiedMillis)
        }

        fun displayNames(): Set<String> = documents.values.mapTo(linkedSetOf()) { it.displayName }

        fun onlyDocumentMimeType(): String = documents.values.single().mimeType

        fun totalDocumentBytes(): Long = documents.values.sumOf { it.bytes.size.toLong() }

        data class StoredDocument(
            var displayName: String,
            var bytes: ByteArray,
            val lastModifiedMillis: Long,
            val mimeType: String = "application/octet-stream",
        )
    }

    private class NonCloneableDigest : MessageDigest("NonCloneable") {
        override fun engineUpdate(input: Byte) = Unit
        override fun engineUpdate(input: ByteArray, offset: Int, len: Int) = Unit
        override fun engineDigest(): ByteArray = ByteArray(32)
        override fun engineReset() = Unit
    }

    private class TrackingInputStream(
        bytes: ByteArray,
    ) : java.io.ByteArrayInputStream(bytes) {
        var totalBytesRead: Long = 0
        var maxRequestedBytes: Int = 0

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            maxRequestedBytes = maxOf(maxRequestedBytes, length)
            return super.read(buffer, offset, length).also { count ->
                if (count > 0) totalBytesRead += count.toLong()
            }
        }
    }

    private companion object {
        const val EIGHT_DAYS = 8L * 24 * 60 * 60 * 1_000
    }
}
