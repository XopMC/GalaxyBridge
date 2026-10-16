package com.xopmc.galaxybridge.nearby

import java.net.URI
import java.net.URLDecoder
import java.util.Base64
import java.util.UUID

/** User-scanned offline offer, kept in memory only. Never rendered by toString/logged. */
class NearbyPairingOffer private constructor(val hostID: String, val sessionID: String, val identity: ByteArray,
    val token: ByteArray, val context: ByteArray, val expiresAtMillis: Long) {
    companion object {
        fun parse(value: String, nowMillis: Long): NearbyPairingOffer {
            require(value.length <= 4096)
            val uri = URI(value)
            require(uri.scheme == "galaxybridge" && uri.host == "pair" && uri.path.orEmpty().isEmpty() && uri.fragment == null && uri.userInfo == null && uri.port == -1)
            val fields = linkedMapOf<String, String>()
            for (part in requireNotNull(uri.rawQuery).split('&')) {
                val pair = part.split('=', limit = 2)
                require(pair.size == 2)
                val name = URLDecoder.decode(pair[0], "UTF-8")
                val text = URLDecoder.decode(pair[1], "UTF-8")
                require(fields.put(name, text) == null)
            }
            require(fields.keys == setOf("transport", "version", "host", "identity", "token", "context", "expires", "sid"))
            require(fields["transport"] == "nearby" && fields["version"] == "1")
            fun uuid(name: String): String = requireNotNull(fields[name]).also { require(UUID.fromString(it).toString() == it) }
            fun bytes(name: String, length: Int): ByteArray {
                val encoded = requireNotNull(fields[name]); require(encoded.matches(Regex("[A-Za-z0-9_-]+")))
                val decoded = Base64.getUrlDecoder().decode(encoded)
                require(decoded.size == length && Base64.getUrlEncoder().withoutPadding().encodeToString(decoded) == encoded)
                return decoded
            }
            val expires = requireNotNull(fields["expires"]).toLong()
            val nowSeconds = nowMillis / 1000
            require(expires > nowSeconds && expires - nowSeconds <= 120)
            val identity = bytes("identity", 65); require(identity[0] == 4.toByte())
            return NearbyPairingOffer(uuid("host"), uuid("sid"), identity, bytes("token", 32), bytes("context", 32), expires * 1000)
        }
    }
}
