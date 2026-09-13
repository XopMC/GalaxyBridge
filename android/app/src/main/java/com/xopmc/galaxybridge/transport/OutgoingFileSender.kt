package com.xopmc.galaxybridge.transport

import com.google.protobuf.ByteString
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.TransferAck
import com.xopmc.galaxybridge.protocol.v1.TransferCancel
import com.xopmc.galaxybridge.protocol.v1.TransferChunk
import com.xopmc.galaxybridge.protocol.v1.TransferManifest
import java.util.UUID

internal class OutgoingFileTransportFailure(cause: Throwable) : Exception(cause)

internal data class OutgoingFileProgress(val record: OutgoingFileRecord, val confirmedOffset: Long = 0,
                                         val waiting: Boolean = false)

/** All methods run on the manager's single IO executor. No network thread mutates sender state. */
internal class OutgoingFileSender(
    private val store: OutgoingFileStore,
    private val currentOwner: () -> String?,
    private val changed: (List<OutgoingFileProgress>, Boolean) -> Unit,
    private val cancelRequested: (String) -> Boolean = { false },
) {
    data class Connection(val id: UUID, val owner: String, val send: (Envelope.Builder) -> Unit)
    private data class Flight(val record: OutgoingFileRecord, val generation: UUID,
                              var acknowledged: Long = -1, var sentEnd: Long = 0, var cancelling: Boolean = false)
    private var connection: Connection? = null
    private val flights = mutableMapOf<String, Flight>()
    private val cancelledBeforeCommit = mutableSetOf<String>()

    fun attach(next: Connection) {
        connection = next
        flights.clear()
        refresh()
    }
    fun detach(id: UUID) {
        if (connection?.id != id) return
        connection = null
        flights.clear()
        publish()
    }
    fun refresh() {
        val active = connection
        val listing = store.list()
        if (active != null && active.owner == currentOwner()) {
            for (record in listing.records.filter { it.owner == active.owner && !it.terminal }) {
                if (connection?.id != active.id) break
                if (record.id in cancelledBeforeCommit || cancelRequested(record.id) || record.id in flights ||
                    record.phase == OutgoingFilePhase.PAUSED || record.phase == OutgoingFilePhase.PREPARED) continue
                val flight = Flight(record, active.id)
                flights[record.id] = flight
                try {
                    if (record.phase == OutgoingFilePhase.CANCEL_REQUESTED) sendCancel(active, flight)
                    else {
                        store.verify(record) { currentOwner() != active.owner || cancelRequested(record.id) }
                        check(connection?.id == active.id && currentOwner() == active.owner)
                        active.send(Envelope.newBuilder().setTransferManifest(TransferManifest.newBuilder()
                            .setTransferId(record.id).setRelativeName(record.name).setSize(record.size)
                            .setMimeType(record.mimeType).setSha256(ByteString.copyFrom(record.sha256))))
                    }
                } catch (error: Exception) { failed(record, error) }
            }
        }
        publish()
    }
    fun acknowledge(generation: UUID, ack: TransferAck) {
        val active = connection ?: return
        if (active.id != generation || active.owner != currentOwner()) return
        val flight = flights[ack.transferId] ?: return
        if (flight.generation != generation || flight.record.owner != active.owner) return
        val record = store.load(ack.transferId) ?: return
        if (record.owner != active.owner || record.terminal) return
        if (record.id in cancelledBeforeCommit || (cancelRequested(record.id) && record.phase != OutgoingFilePhase.CANCEL_REQUESTED)) return
        try {
            check(!ack.complete || ack.failureReason.isEmpty()) { "conflicting_completion_receipt" }
            if (ack.failureReason == "transfer_cancelled") {
                store.transition(record.id, active.owner, OutgoingFilePhase.CANCELLED)
                flights.remove(record.id)
            } else if (ack.failureReason.isNotEmpty()) {
                pause(record)
            } else if (ack.complete) {
                check(ack.confirmedOffset == record.size && OutgoingFileStore.validName(ack.publishedName)) {
                    "invalid_completion"
                }
                // A receiver may have published before the user's cancellation arrived.
                store.transition(record.id, active.owner, OutgoingFilePhase.COMPLETED, ack.publishedName)
                flights.remove(record.id)
            } else if (record.phase == OutgoingFilePhase.CANCEL_REQUESTED || flight.cancelling) {
                if (!flight.cancelling) sendCancel(active, flight)
            } else {
                check(ack.confirmedOffset in 0..record.size) { "invalid_confirmed_offset" }
                if (flight.acknowledged >= 0) {
                    if (ack.confirmedOffset <= flight.acknowledged) return // Replayed ACK cannot schedule another chunk.
                    check(ack.confirmedOffset == flight.sentEnd) { "invalid_confirmed_offset" }
                }
                flight.acknowledged = ack.confirmedOffset
                check(ack.confirmedOffset < record.size) { "missing_completion_receipt" }
                val content = store.read(record, ack.confirmedOffset)
                check(currentOwner() == active.owner)
                flight.sentEnd = ack.confirmedOffset + content.size
                active.send(Envelope.newBuilder().setTransferChunk(TransferChunk.newBuilder()
                    .setTransferId(record.id).setOffset(ack.confirmedOffset)
                    .setContent(ByteString.copyFrom(content))))
            }
        } catch (error: Exception) { failed(record, error) }
        publish()
    }
    fun cancel(id: String, owner: String) {
        if (owner != currentOwner()) return
        cancelledBeforeCommit.add(id)
        try {
            if (store.load(id)?.let { it.owner == owner && it.phase == OutgoingFilePhase.PREPARED } == true) {
                store.transition(id, owner, OutgoingFilePhase.CANCELLED)
                cancelledBeforeCommit.remove(id)
                return
            }
            val cancelled = store.transition(id, owner, OutgoingFilePhase.CANCEL_REQUESTED)
            cancelledBeforeCommit.remove(id)
            if (cancelled.terminal) { publish(); return }
            val active = connection
            if (active?.owner == owner) {
                val flight = Flight(cancelled, active.id)
                flights[id] = flight
                sendCancel(active, flight)
            }
        } finally { publish() }
    }
    fun retry(id: String, owner: String) {
        if (owner != currentOwner()) return
        val record = store.load(id) ?: return
        check(record.owner == owner)
        if (record.terminal || record.phase == OutgoingFilePhase.PREPARED) return
        if (record.id in cancelledBeforeCommit) { cancel(id, owner); return }
        if (record.phase != OutgoingFilePhase.CANCEL_REQUESTED) store.transition(id, owner, OutgoingFilePhase.QUEUED)
        flights.remove(id)
        refresh()
    }
    fun timeout(generation: UUID) {
        if (connection?.id != generation) return
        flights.values.toList().forEach { pause(it.record) }
        detach(generation)
    }
    private fun sendCancel(active: Connection, flight: Flight) {
        flight.cancelling = true
        check(active.owner == currentOwner())
        active.send(Envelope.newBuilder().setTransferCancel(TransferCancel.newBuilder().setTransferId(flight.record.id)))
    }
    private fun pause(record: OutgoingFileRecord) {
        flights.remove(record.id)
        val current = store.load(record.id) ?: return
        if (!current.terminal && current.phase != OutgoingFilePhase.CANCEL_REQUESTED) {
            store.transition(record.id, record.owner, OutgoingFilePhase.PAUSED)
        }
    }
    private fun failed(record: OutgoingFileRecord, error: Exception) {
        if (error is OutgoingFileTransportFailure) {
            connection = null
            flights.clear() // Receiver's checkpoint is authoritative after reconnect.
        } else pause(record)
    }
    private fun publish() {
        val listing = store.list()
        val owner = currentOwner()
        changed(listing.records.filter { it.owner == owner }.map { record ->
            val flight = flights[record.id]
            OutgoingFileProgress(record, if (record.phase == OutgoingFilePhase.COMPLETED) record.size
                else flight?.acknowledged?.coerceAtLeast(0) ?: 0, flight != null)
        }, listing.rejected > 0 || cancelledBeforeCommit.isNotEmpty())
    }
}
