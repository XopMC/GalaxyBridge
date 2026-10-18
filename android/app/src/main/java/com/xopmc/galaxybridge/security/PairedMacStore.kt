package com.xopmc.galaxybridge.security

import android.content.Context
import android.util.AtomicFile
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest

/** Every component sees one immutable snapshot, published only after durable writes. */
class PairedMacStore(context: Context) {
    private val repository = repositories.repository(context.applicationInfo.dataDir) {
        AndroidTrustedMacStorage(context.applicationContext)
    }

    fun snapshot(): TrustedMacRoster = repository.snapshot()
    fun add(mac: TrustedMac): Boolean = repository.add(mac)
    fun forget(hostID: String): Boolean = repository.forget(hostID)
    // The handoff coordinator must settle old interactive resources before calling this.
    internal fun select(hostID: String, expectedEpoch: Long): Boolean = repository.select(hostID, expectedEpoch)
    internal fun reconcileAfterRetirement(): TrustedMacRoster = repository.reconcileAfterRetirement()

    companion object {
        const val ROSTER_KEY = "trusted_macs_v1"
        private val repositories = TrustedMacRepositoryRegistry()
    }
}

private class AndroidTrustedMacStorage(context: Context) : TrustedMacStorage {
    private val preferences = context.applicationContext.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    private val file = AtomicFile(File(context.applicationContext.filesDir, "trusted-macs-v1"))
    override fun read(): String? = try {
        file.openRead().use { input ->
            val bytes = ByteArray(16385)
            var length = 0
            while (length < bytes.size) {
                val count = input.read(bytes, length, bytes.size - length)
                if (count == -1) break
                length += count
            }
            check(length <= 16384) { "trusted_mac_storage_oversized" }
            String(bytes, 0, length, Charsets.US_ASCII)
        }
    } catch (error: FileNotFoundException) {
        check(!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) { "trusted_mac_storage_unreadable" }
        null
    }
    override fun readLegacy(): TrustedMac? {
        val host = preferences.getString("paired_host_id", null)
        val key = preferences.getString("paired_mac_key", null)
        if (host == null && key == null) return null
        check(host != null && key != null) { "legacy_pairing_incomplete" }
        return TrustedMac(host, key, "Mac", preferences.getLong("paired_at", 0))
    }
    override fun write(encoded: String): Boolean = TrustedMacPublication.commit(encoded, ::read, ::replace)

    private fun replace(encoded: String) {
        // SharedPreferences.commit(false) still changes its in-memory map.
        // Keep authoritative trust in a rollback-capable atomic file instead.
        val output = file.startWrite()
        var publicationAttempted = false
        try {
            output.write(encoded.toByteArray(Charsets.US_ASCII))
            output.fd.sync()
            publicationAttempted = true
            file.finishWrite(output)
            try {
                val directory = Os.open(requireNotNull(file.baseFile.parent),
                    OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
                try {
                    check(OsConstants.S_ISDIR(Os.fstat(directory).st_mode))
                    Os.fsync(directory)
                } finally { Os.close(directory) }
            } catch (error: Exception) {
                throw TrustedMacStorageUncertain(error)
            }
        } catch (error: Exception) {
            if (!publicationAttempted) file.failWrite(output)
            else if (error !is TrustedMacStorageUncertain) throw TrustedMacStorageUncertain(error)
            throw error
        }
    }
    override fun committed(snapshot: TrustedMacRoster) {
        // Notify after the repository publishes the committed snapshot.
        val revision = MessageDigest.getInstance("SHA-256").digest(snapshot.encode().toByteArray(Charsets.US_ASCII))
            .joinToString("") { "%02x".format(it) }
        preferences.edit().putString(PairedMacStore.ROSTER_KEY, revision)
            .remove("paired_host_id").remove("paired_mac_key").remove("paired_at").commit()
    }
}
