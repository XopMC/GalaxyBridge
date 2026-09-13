package com.xopmc.galaxybridge.core

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.UUID

data class PairingPayload(
    val version: UInt,
    val hostId: UUID,
    val addresses: List<String>,
    val port: Int,
    val token: ByteArray,
    val publicKeyFingerprint: ByteArray,
    val expiresAtEpochSeconds: Long,
)

class InvalidPairingUri(val field: String) : IllegalArgumentException("invalid pairing field: $field")
class ExpiredPairingUri : IllegalArgumentException("pairing token expired")

object PairingUriCodec {
    const val SUPPORTED_VERSION = 1
    const val TOKEN_LENGTH = 32
    const val FINGERPRINT_LENGTH = 32
    const val MAXIMUM_TTL_SECONDS = 120L

    fun decode(value: String, nowEpochSeconds: Long): PairingPayload {
        val uri = runCatching { URI(value) }.getOrElse { throw InvalidPairingUri("url") }
        if (uri.scheme != "galaxybridge" || uri.host != "pair" || uri.userInfo != null || uri.fragment != null) {
            throw InvalidPairingUri("url")
        }

        val fields = parseQuery(uri.rawQuery ?: throw InvalidPairingUri("query"))
        fun singleton(name: String): String {
            val values = fields[name] ?: throw InvalidPairingUri(name)
            if (values.size != 1 || values.single().isEmpty()) throw InvalidPairingUri(name)
            return values.single()
        }

        val version = singleton("v").toUIntOrNull() ?: throw InvalidPairingUri("v")
        if (version != SUPPORTED_VERSION.toUInt()) throw InvalidPairingUri("v")
        val hostId = runCatching { UUID.fromString(singleton("host")) }
            .getOrElse { throw InvalidPairingUri("host") }
        val port = singleton("port").toIntOrNull() ?: throw InvalidPairingUri("port")
        if (port !in 1..65535) throw InvalidPairingUri("port")
        val token = decodeBase64Url(singleton("token"), "token")
        if (token.size != TOKEN_LENGTH) throw InvalidPairingUri("token")
        val fingerprint = decodeBase64Url(singleton("fp"), "fp")
        if (fingerprint.size != FINGERPRINT_LENGTH) throw InvalidPairingUri("fp")
        val expiresAt = singleton("exp").toLongOrNull() ?: throw InvalidPairingUri("exp")
        if (expiresAt <= nowEpochSeconds) throw ExpiredPairingUri()
        if (expiresAt - nowEpochSeconds > MAXIMUM_TTL_SECONDS) throw InvalidPairingUri("exp")
        val addresses = fields["addr"].orEmpty()
        if (addresses.isEmpty() || addresses.size > 8 || addresses.any { !isSafeAddress(it) }) {
            throw InvalidPairingUri("addr")
        }

        return PairingPayload(version, hostId, addresses, port, token, fingerprint, expiresAt)
    }

    private fun parseQuery(query: String): Map<String, List<String>> {
        val result = linkedMapOf<String, MutableList<String>>()
        query.split('&').forEach { component ->
            val separator = component.indexOf('=')
            if (separator <= 0) throw InvalidPairingUri("query")
            val name = decode(component.substring(0, separator))
            val value = decode(component.substring(separator + 1))
            result.getOrPut(name) { mutableListOf() }.add(value)
        }
        return result
    }

    private fun decode(value: String): String =
        runCatching { URLDecoder.decode(value, StandardCharsets.UTF_8.name()) }
            .getOrElse { throw InvalidPairingUri("query") }

    private fun decodeBase64Url(value: String, field: String): ByteArray =
        runCatching { Base64.getUrlDecoder().decode(value) }
            .getOrElse { throw InvalidPairingUri(field) }

    private fun isSafeAddress(address: String): Boolean =
        address.isNotEmpty() &&
            address.toByteArray(StandardCharsets.UTF_8).size <= 255 &&
            address.all { it.isLetterOrDigit() || it in ".:-_%" }
}
