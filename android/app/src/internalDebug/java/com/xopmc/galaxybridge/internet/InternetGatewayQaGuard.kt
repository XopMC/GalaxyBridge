package com.xopmc.galaxybridge.internet

import java.security.MessageDigest
import java.util.UUID

/** No Android dependencies: fixed deadline and exact run/token authorization. */
internal class InternetGatewayQaGuard(val runID: String, token: String, started: Long) {
    val deadline = started + 30_000
    private val digest = hash(token)
    fun matches(id: String, token: String) = id == runID && valid(id, token, "status") &&
        MessageDigest.isEqual(digest, hash(token))
    fun authorizes(id: String, token: String, now: Long) = now < deadline && matches(id, token)
    companion object {
        fun valid(id: String?, token: String?, operation: String?) =
            id != null && runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false) &&
            token != null && token.matches(Regex("[0-9a-f]{64}")) && operation in setOf("prepare", "status", "cleanup")
        private fun hash(token: String) = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.US_ASCII))
    }
}
