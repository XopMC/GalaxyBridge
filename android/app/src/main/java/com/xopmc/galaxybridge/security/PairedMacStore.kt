package com.xopmc.galaxybridge.security

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException

/** Shared by pairing, authenticated sessions and phone UI. No process-local trust cache. */
class PairedMacStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    private val file = AtomicFile(File(context.applicationContext.filesDir, "trusted-macs-v1"))
    private val repository = TrustedMacRepository(object : TrustedMacStorage {
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
        override fun write(encoded: String): Boolean {
            // SharedPreferences.commit(false) still changes its in-memory map.
            // Keep authoritative trust in a rollback-capable atomic file instead.
            val output = runCatching { file.startWrite() }.getOrNull() ?: return false
            try {
                output.write(encoded.toByteArray(Charsets.US_ASCII))
                output.fd.sync()
                file.finishWrite(output)
                if (read() != encoded) return false
            } catch (_: Exception) {
                file.failWrite(output)
                return false
            }
            // This is a change notification only. Readers always load the file.
            // Legacy cleanup happens after durable publication, never before it.
            preferences.edit().putString(ROSTER_KEY, encoded)
                .remove("paired_host_id").remove("paired_mac_key").remove("paired_at").commit()
            return true
        }
    })

    fun snapshot(): TrustedMacRoster = repository.snapshot()
    fun add(mac: TrustedMac): Boolean = repository.add(mac)
    fun forget(hostID: String): Boolean = repository.forget(hostID)
    // The handoff coordinator must settle old interactive resources before calling this.
    internal fun select(hostID: String, expectedEpoch: Long): Boolean = repository.select(hostID, expectedEpoch)

    companion object { const val ROSTER_KEY = "trusted_macs_v1" }
}
