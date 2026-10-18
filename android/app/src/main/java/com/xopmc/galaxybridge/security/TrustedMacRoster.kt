package com.xopmc.galaxybridge.security

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.Base64
import java.util.UUID

/** Public identities only. Private signing keys never leave their Mac. */
data class TrustedMac(
    val hostID: String,
    val publicKeyBase64: String,
    val displayName: String,
    val pairedAtMillis: Long,
) {
    internal fun validated(): TrustedMac {
        require(UUID.fromString(hostID).toString() == hostID)
        require(publicKeyBase64.length == 88 && pairedAtMillis > 0)
        val key = Base64.getDecoder().decode(publicKeyBase64)
        require(key.size == 65 && key[0] == 4.toByte() &&
            Base64.getEncoder().encodeToString(key) == publicKeyBase64)
        return copy(displayName = cleanName(displayName))
    }

    companion object {
        private fun cleanName(value: String): String = buildString {
            value.take(1024).codePoints().forEach { point ->
                if (Character.isISOControl(point) && length < 80) append(' ')
                else if (Character.getType(point) != Character.FORMAT.toInt() && length + Character.charCount(point) <= 80)
                    appendCodePoint(point)
            }
        }.trim().ifEmpty { "Mac" }
    }
}

/** Immutable roster snapshot; selecting a host is separate from adding its trust. */
class TrustedMacRoster(macs: List<TrustedMac>, val activeHostID: String?, val epoch: Long) {
    val macs: List<TrustedMac> = java.util.Collections.unmodifiableList(macs.toList())

    init {
        require(this.macs.size <= MAX_MACS && epoch >= 0)
        require(this.macs.map { it.hostID }.toSet().size == this.macs.size)
        require(this.macs.all { it.validated() == it })
        require(activeHostID == null || this.macs.any { it.hostID == activeHostID })
    }

    fun find(hostID: String): TrustedMac? = macs.firstOrNull { it.hostID == hostID }

    internal fun adding(value: TrustedMac): TrustedMacRoster {
        val candidate = value.validated()
        val previous = find(candidate.hostID)
        require(previous == null || previous.publicKeyBase64 == candidate.publicKeyBase64) { "trusted_mac_key_changed" }
        val next = if (previous == null) macs + candidate else macs.map {
            if (it.hostID == candidate.hostID) candidate.copy(pairedAtMillis = it.pairedAtMillis) else it
        }
        return TrustedMacRoster(next, if (macs.isEmpty()) candidate.hostID else activeHostID, epoch)
    }

    internal fun removing(hostID: String): TrustedMacRoster = if (hostID != activeHostID)
        TrustedMacRoster(macs.filterNot { it.hostID == hostID }, activeHostID, epoch)
    else TrustedMacRoster(macs.filterNot { it.hostID == hostID }, null, nextEpoch())

    internal fun selecting(hostID: String): TrustedMacRoster {
        require(find(hostID) != null)
        return if (activeHostID == hostID) this else TrustedMacRoster(macs, hostID, nextEpoch())
    }

    private fun nextEpoch(): Long {
        check(epoch < Long.MAX_VALUE) { "trusted_mac_epoch_exhausted" }
        return epoch + 1
    }

    fun encode(): String {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { output ->
            output.writeInt(MAGIC)
            output.writeLong(epoch)
            output.writeUTF(activeHostID.orEmpty())
            output.writeInt(macs.size)
            macs.forEach { mac ->
                output.writeUTF(mac.hostID)
                output.writeUTF(mac.publicKeyBase64)
                output.writeUTF(mac.displayName)
                output.writeLong(mac.pairedAtMillis)
            }
        }
        return Base64.getEncoder().encodeToString(bytes.toByteArray())
    }

    override fun equals(other: Any?): Boolean = other is TrustedMacRoster &&
        macs == other.macs && activeHostID == other.activeHostID && epoch == other.epoch
    override fun hashCode(): Int = 31 * (31 * macs.hashCode() + (activeHostID?.hashCode() ?: 0)) + epoch.hashCode()

    companion object {
        const val MAX_MACS = 16
        private const val MAGIC = 0x47424d31 // GBM1
        private const val MAX_ENCODED_BYTES = 16384

        fun decode(encoded: String): TrustedMacRoster {
            require(encoded.length in 1..MAX_ENCODED_BYTES)
            return try {
                val bytes = Base64.getDecoder().decode(encoded)
                require(Base64.getEncoder().encodeToString(bytes) == encoded)
                DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                    require(input.readInt() == MAGIC)
                    val epoch = input.readLong()
                    val active = input.readUTF().ifEmpty { null }
                    val count = input.readInt()
                    require(count in 0..MAX_MACS)
                    val macs = List(count) { TrustedMac(input.readUTF(), input.readUTF(), input.readUTF(), input.readLong()) }
                    require(input.available() == 0)
                    TrustedMacRoster(macs, active, epoch)
                }
            } catch (error: Exception) {
                throw IllegalArgumentException("invalid_trusted_mac_roster", error)
            }
        }
    }
}

/** write must atomically persist the whole snapshot and retire legacy keys. */
internal interface TrustedMacStorage {
    fun read(): String?
    fun readLegacy(): TrustedMac?
    fun write(encoded: String): Boolean
}

internal class TrustedMacRepository(private val storage: TrustedMacStorage) {
    fun snapshot(): TrustedMacRoster = synchronized(lock) { load() }
    fun add(mac: TrustedMac): Boolean = synchronized(lock) { storage.write(load().adding(mac).encode()) }
    fun forget(hostID: String): Boolean = synchronized(lock) { storage.write(load().removing(hostID).encode()) }
    fun select(hostID: String, expectedEpoch: Long): Boolean = synchronized(lock) {
        val current = load()
        if (current.epoch != expectedEpoch || current.find(hostID) == null) return@synchronized false
        val next = current.selecting(hostID)
        if (next === current) true else storage.write(next.encode())
    }

    private fun load(): TrustedMacRoster {
        val encoded = storage.read()
        if (encoded != null) return try { TrustedMacRoster.decode(encoded) }
            catch (error: IllegalArgumentException) { throw IllegalStateException("trusted_mac_storage_invalid", error) }
        val legacy = storage.readLegacy() ?: return TrustedMacRoster(emptyList(), null, 0)
        val migrated = TrustedMacRoster(listOf(legacy.validated()), legacy.hostID, 0)
        // An unsuccessful migration keeps the original identity usable. Any
        // subsequent mutation still needs its own successful durable commit.
        storage.write(migrated.encode())
        return migrated
    }

    companion object { private val lock = Any() }
}
