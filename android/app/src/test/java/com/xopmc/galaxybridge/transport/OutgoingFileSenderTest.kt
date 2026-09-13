package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.TransferAck
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardOpenOption.READ
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class OutgoingFileSenderTest {
    private val owner = "a".repeat(64)
    private val other = "b".repeat(64)
    private class Fixture(val root: File) {
        var failCommit = false
        val store = OutgoingFileStore(File(root, "outgoing")) { directory ->
            if (failCommit && File(directory, "record").exists()) throw IOException("fixture fsync failure")
            FileChannel.open(directory.toPath(), READ).use { it.force(true) }
        }
    }
    private fun fixture(body: (Fixture) -> Unit) {
        val root = Files.createTempDirectory("gb-outgoing-test").toFile().canonicalFile
        try { body(Fixture(root)) } finally { root.deleteRecursively() }
    }
    private fun prepare(f: Fixture, bytes: ByteArray = "payload".toByteArray(), name: String = "payload.bin") =
        f.store.prepare(owner, name, "application/octet-stream", { ByteArrayInputStream(bytes) })
    private fun ack(record: OutgoingFileRecord, offset: Long, complete: Boolean = false, failure: String = "", name: String = "") =
        TransferAck.newBuilder().setTransferId(record.id).setConfirmedOffset(offset).setComplete(complete)
            .setFailureReason(failure).setPublishedName(name).build()

    @Test fun privateSnapshotAndJournalSurviveRestartWithoutOriginal() = fixture { f ->
        val source = File(f.root, "original").apply { writeText("immutable bytes") }
        val record = f.store.prepare(owner, "copy.bin", "application/octet-stream", { source.inputStream() })
        source.writeText("changed")
        val restored = OutgoingFileStore(File(f.root, "outgoing")) {}.list().records.single()
        assertEquals(record.id, restored.id)
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest("immutable bytes".toByteArray()), restored.sha256)
        assertArrayEquals("immutable bytes".toByteArray(), f.store.read(restored, 0))
        assertEquals("r--------", PosixFilePermissions.toString(Files.getPosixFilePermissions(File(f.root, "outgoing/${record.id}/payload").toPath())))
    }

    @Test fun cancellationDuringCopyLeavesNoResumableTransfer() = fixture { f ->
        var cancelled = false
        val stream = object : ByteArrayInputStream(ByteArray(100)) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                cancelled = true
                return super.read(bytes, offset, length)
            }
        }
        assertThrows(IllegalStateException::class.java) {
            f.store.prepare(owner, "cancel.bin", "application/octet-stream", { stream }, { cancelled })
        }
        assertTrue(f.store.list().records.isEmpty())
        assertTrue(File(f.root, "outgoing").listFiles()!!.isEmpty())
    }

    @Test fun uncertainJournalCommitPreservesPayloadForRecovery() = fixture { f ->
        f.failCommit = true
        assertThrows(IOException::class.java) { prepare(f) }
        f.failCommit = false
        val restored = f.store.list().records.single()
        f.store.verify(restored)
        assertArrayEquals("payload".toByteArray(), f.store.read(restored, 0))
    }

    @Test fun corruptJournalAndSymlinkArePreservedAndRejected() = fixture { f ->
        val record = prepare(f)
        val journal = File(f.root, "outgoing/${record.id}/record")
        journal.writeText("corrupt")
        assertEquals(1, f.store.list().rejected)
        assertEquals("corrupt", journal.readText())
        val another = prepare(f, name = "other.bin")
        val payload = File(f.root, "outgoing/${another.id}/payload")
        Files.delete(payload.toPath())
        val sentinel = File(f.root, "outside").apply { writeText("outside") }
        Files.createSymbolicLink(payload.toPath(), sentinel.toPath())
        assertThrows(IllegalStateException::class.java) { f.store.verify(another) }
        assertEquals("outside", sentinel.readText())
    }

    @Test fun manifestThenOneChunkPerValidAckAndDurableCompletion() = fixture { f ->
        val bytes = ByteArray(OutgoingFileStore.CHUNK_SIZE + 13) { (it % 251).toByte() }
        val record = prepare(f, bytes)
        val sent = mutableListOf<Envelope>()
        var state = emptyList<OutgoingFileProgress>()
        val sender = OutgoingFileSender(f.store, { owner }, { value, _ -> state = value })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) { sent += it.build() })
        assertEquals(listOf(Envelope.PayloadCase.TRANSFER_MANIFEST), sent.map { it.payloadCase })
        assertNotEquals(OutgoingFilePhase.COMPLETED, state.single().record.phase)
        sender.acknowledge(generation, ack(record, 0))
        assertEquals(OutgoingFileStore.CHUNK_SIZE, sent.last().transferChunk.content.size())
        sender.acknowledge(generation, ack(record, 0))
        assertEquals(2, sent.size)
        sender.acknowledge(generation, ack(record, OutgoingFileStore.CHUNK_SIZE.toLong()))
        assertEquals(13, sent.last().transferChunk.content.size())
        sender.acknowledge(generation, ack(record, bytes.size.toLong(), true, name = "payload (1).bin"))
        assertEquals(OutgoingFilePhase.COMPLETED, f.store.load(record.id)!!.phase)
        assertEquals("payload (1).bin", state.single().record.publishedName)
        assertFalse(File(f.root, "outgoing/${record.id}/payload").exists())
    }

    @Test fun reconnectResendsManifestAndUsesReceiverOffsetNotPreviouslySentBytes() = fixture { f ->
        val record = prepare(f, ByteArray(20) { it.toByte() })
        val sent = mutableListOf<Envelope>()
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        val old = UUID.randomUUID(); val fresh = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(old, owner) { sent += it.build() })
        sender.acknowledge(old, ack(record, 0))
        sender.detach(old)
        sender.attach(OutgoingFileSender.Connection(fresh, owner) { sent += it.build() })
        assertTrue(sent.last().hasTransferManifest())
        sender.acknowledge(old, ack(record, 20, true, name = "bad.bin"))
        assertEquals(OutgoingFilePhase.QUEUED, f.store.load(record.id)!!.phase)
        sender.acknowledge(fresh, ack(record, 7))
        assertEquals(7L, sent.last().transferChunk.offset)
        assertEquals(13, sent.last().transferChunk.content.size())
    }

    @Test fun persistedCancelCannotBeRearmedByRetryOrLateDataAck() = fixture { f ->
        val record = prepare(f)
        val sent = mutableListOf<Envelope>()
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) { sent += it.build() })
        sender.cancel(record.id, owner)
        sender.acknowledge(generation, ack(record, 0))
        assertFalse(sent.any { it.hasTransferChunk() })
        assertEquals(OutgoingFilePhase.CANCEL_REQUESTED, f.store.load(record.id)!!.phase)
        val restarted = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        restarted.attach(OutgoingFileSender.Connection(generation, owner) { sent += it.build() })
        assertTrue(sent.last().hasTransferCancel())
        restarted.retry(record.id, owner)
        assertTrue(sent.last().hasTransferCancel())
        restarted.acknowledge(generation, ack(record, 0, failure = "transfer_cancelled"))
        assertEquals(OutgoingFilePhase.CANCELLED, f.store.load(record.id)!!.phase)
    }

    @Test fun pairingRotationAndForgedCompletionNeverPass() = fixture { f ->
        val record = prepare(f)
        var current = owner
        val sender = OutgoingFileSender(f.store, { current }, { _, _ -> })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) {})
        current = other
        sender.acknowledge(generation, ack(record, record.size, true, name = "final.bin"))
        assertEquals(OutgoingFilePhase.QUEUED, f.store.load(record.id)!!.phase)
        current = owner
        sender.acknowledge(generation, ack(record, record.size, true, name = "../bad"))
        assertEquals(OutgoingFilePhase.PAUSED, f.store.load(record.id)!!.phase)
        assertTrue(File(f.root, "outgoing/${record.id}/payload").exists())
    }

    @Test fun socketFailurePreservesAutomaticResumeAndChangedSnapshotFailsClosed() = fixture { f ->
        val record = prepare(f)
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        sender.attach(OutgoingFileSender.Connection(UUID.randomUUID(), owner) { throw OutgoingFileTransportFailure(IOException()) })
        assertEquals(OutgoingFilePhase.QUEUED, f.store.load(record.id)!!.phase)
        val payload = File(f.root, "outgoing/${record.id}/payload")
        Files.setPosixFilePermissions(payload.toPath(), PosixFilePermissions.fromString("rw-------"))
        payload.writeText("changed")
        var sends = 0
        sender.attach(OutgoingFileSender.Connection(UUID.randomUUID(), owner) { sends++ })
        assertEquals(0, sends)
        assertEquals(OutgoingFilePhase.PAUSED, f.store.load(record.id)!!.phase)
    }

    @Test fun earlyCancellationFenceStopsAckBeforeDurableCancelRuns() = fixture { f ->
        val record = prepare(f)
        var cancellation = false
        val sent = mutableListOf<Envelope>()
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> }, { cancellation })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) { sent += it.build() })
        cancellation = true
        sender.acknowledge(generation, ack(record, 0))
        assertFalse(sent.any { it.hasTransferChunk() })
        sender.cancel(record.id, owner)
        assertTrue(sent.last().hasTransferCancel())
    }

    @Test fun preparedButNotAdmittedCopyCannotSendAfterRefreshOrRetry() = fixture { f ->
        val record = f.store.prepare(owner, "prepared.bin", "application/octet-stream",
            { ByteArrayInputStream("prepared".toByteArray()) }, initialPhase = OutgoingFilePhase.PREPARED)
        var sends = 0
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        sender.attach(OutgoingFileSender.Connection(UUID.randomUUID(), owner) { sends++ })
        sender.retry(record.id, owner)
        assertEquals(0, sends)
        f.store.transition(record.id, owner, OutgoingFilePhase.QUEUED)
        sender.refresh()
        assertEquals(1, sends)
    }

    @Test fun emptyFileNeedsActualDurableCompletionReceipt() = fixture { f ->
        val record = prepare(f, byteArrayOf())
        var sends = 0
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) { sends++ })
        assertEquals(OutgoingFilePhase.QUEUED, f.store.load(record.id)!!.phase)
        sender.acknowledge(generation, ack(record, 0, true, name = "empty.bin"))
        assertEquals(1, sends)
        assertEquals(OutgoingFilePhase.COMPLETED, f.store.load(record.id)!!.phase)
    }

    @Test fun impossibleOffsetDoesNotReadOrPublishAndLimitIsBounded() = fixture { f ->
        val record = prepare(f)
        val sent = mutableListOf<Envelope>()
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) { sent += it.build() })
        sender.acknowledge(generation, ack(record, record.size + 1))
        assertEquals(1, sent.size)
        assertEquals(OutgoingFilePhase.PAUSED, f.store.load(record.id)!!.phase)
        repeat(OutgoingFileStore.MAX_ACTIVE - 1) { prepare(f) }
        assertThrows(IllegalStateException::class.java) { prepare(f) }
    }

    @Test fun cancellationPersistenceFailureStillBlocksLateAckAndCanRetryCancellation() = fixture { f ->
        val record = prepare(f)
        val sent = mutableListOf<Envelope>()
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) { sent += it.build() })
        f.failCommit = true
        assertThrows(IOException::class.java) { sender.cancel(record.id, owner) }
        sender.acknowledge(generation, ack(record, 0))
        assertFalse(sent.any { it.hasTransferChunk() })
        f.failCommit = false
        sender.retry(record.id, owner)
        assertTrue(sent.last().hasTransferCancel())
        sender.acknowledge(generation, ack(record, 0, failure = "transfer_cancelled"))
        assertEquals(OutgoingFilePhase.CANCELLED, f.store.load(record.id)!!.phase)
    }

    @Test fun publishedBeforeCancelWinsOnlyWithExactCompletionReceipt() = fixture { f ->
        val record = prepare(f)
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) {})
        sender.cancel(record.id, owner)
        sender.acknowledge(generation, ack(record, record.size, true, name = "already-published.bin"))
        assertEquals(OutgoingFilePhase.COMPLETED, f.store.load(record.id)!!.phase)
        assertEquals("already-published.bin", f.store.load(record.id)!!.publishedName)
    }

    @Test fun timeoutAndWrongCompletionOffsetDoNotPretendSuccess() = fixture { f ->
        val record = prepare(f)
        val sender = OutgoingFileSender(f.store, { owner }, { _, _ -> })
        val generation = UUID.randomUUID()
        sender.attach(OutgoingFileSender.Connection(generation, owner) {})
        sender.acknowledge(generation, ack(record, record.size - 1, true, name = "bad.bin"))
        assertEquals(OutgoingFilePhase.PAUSED, f.store.load(record.id)!!.phase)
        sender.retry(record.id, owner)
        sender.acknowledge(generation, ack(record, record.size, true, "transfer_cancelled", "conflict.bin"))
        assertEquals(OutgoingFilePhase.PAUSED, f.store.load(record.id)!!.phase)
        sender.retry(record.id, owner)
        sender.timeout(generation)
        sender.acknowledge(generation, ack(record, record.size, true, name = "late.bin"))
        assertEquals(OutgoingFilePhase.PAUSED, f.store.load(record.id)!!.phase)
        assertTrue(File(f.root, "outgoing/${record.id}/payload").exists())
    }
}
