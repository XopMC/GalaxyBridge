package com.xopmc.galaxybridge.core

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.util.Locale

/** One process-local, connection-scoped request. No trust is stored by this UI policy. */
class NearbyConsent {
    enum class Decision { PENDING, APPROVED, REJECTED, EXPIRED, BUSY, UNAVAILABLE }
    data class Prompt(val id: String, val name: String, val comparison: String)
    private var visible = false
    private var prompt: Prompt? = null
    private var decision = Decision.PENDING
    private var deadline = 0L
    private var cooldown = 0L
    val pending: Prompt? get() = prompt?.takeIf { decision == Decision.PENDING }
    fun setVisible(value: Boolean) {
        visible = value
        if (!value && prompt != null) decision = Decision.REJECTED
    }
    fun expire(now: Long) {
        if (prompt != null && now >= deadline) {
            prompt = null; cooldown = maxOf(cooldown,deadline + 60_000)
        }
    }
    fun request(id: String, name: String, comparison: String, now: Long): Decision {
        expire(now)
        val existing = prompt
        if (existing != null) {
            if (existing.id != id) return Decision.BUSY
            if (now >= deadline) decision = Decision.EXPIRED
            if (existing.name != cleanName(name) || existing.comparison != comparison) decision = Decision.REJECTED
            return decision
        }
        if (!visible) return Decision.UNAVAILABLE
        if (now < cooldown) return Decision.BUSY
        require(id.length in 1..256 && comparison.matches(Regex("[0-9]{6}")))
        prompt = Prompt(id, cleanName(name), comparison)
        deadline = now + 60_000; decision = Decision.PENDING
        return decision
    }
    fun answer(id: String, approve: Boolean, now: Long): Boolean {
        if (!visible || prompt?.id != id || decision != Decision.PENDING || now >= deadline) return false
        decision = if (approve) Decision.APPROVED else Decision.REJECTED
        return true
    }
    fun retire(id: String, now: Long) {
        if (prompt?.id != id) return
        prompt = null; cooldown = now + 60_000
    }
    companion object {
        fun cleanName(value: String): String = value.filter {
            !Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt()
        }.trim().take(80).ifEmpty { "Mac" }
        private fun encode(fields: List<ByteArray>): ByteArray {
            val out = ByteArrayOutputStream()
            DataOutputStream(out).use { data -> fields.forEach { data.writeInt(it.size); data.write(it) } }
            return out.toByteArray()
        }
        fun context(token: ByteArray, identity: ByteArray, name: String): ByteArray =
            "GBCons01".toByteArray() + MessageDigest.getInstance("SHA-256").digest(encode(listOf(
                "GalaxyBridge/Nearby/ConsentContext/v1".toByteArray(),token,identity,name.toByteArray()
            ))).copyOf(24)
        fun isContext(value: ByteArray): Boolean = value.size == 32 && value.copyOf(8).contentEquals("GBCons01".toByteArray())
        fun comparison(vararg fields: ByteArray): String {
            val out = ByteArrayOutputStream()
            DataOutputStream(out).use { data ->
                for (value in listOf("GalaxyBridge/Nearby/ConsentComparison/v1".toByteArray()) + fields) {
                    data.writeInt(value.size); data.write(value)
                }
            }
            val hash = MessageDigest.getInstance("SHA-256").digest(out.toByteArray())
            val number = hash.take(4).fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 255) }
            return String.format(Locale.ROOT, "%06d", number % 1_000_000)
        }
    }
}
