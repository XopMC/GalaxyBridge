package com.xopmc.galaxybridge.nearby

import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class NearbyPairingOfferTest {
    private fun offer(expires: Long = 1120): String {
        fun encoded(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        val identity = ByteArray(65).apply { this[0] = 4 }
        return "galaxybridge://pair?transport=nearby&version=1&host=69830b65-6352-4b3a-8a21-70bcda45787e" +
            "&identity=${encoded(identity)}&token=${encoded(ByteArray(32) { 1 })}&context=${encoded(ByteArray(32) { 2 })}" +
            "&expires=$expires&sid=d5e1590c-47fb-4d73-9ac2-45988ba0a876"
    }
    @Test fun validOfflineQrKeepsExactTokenContextAndBoundedLifetime() {
        val parsed = NearbyPairingOffer.parse(offer(), 1_000_000)
        assertEquals(1_120_000L, parsed.expiresAtMillis)
        assertArrayEquals(ByteArray(32) { 1 }, parsed.token)
        assertArrayEquals(ByteArray(32) { 2 }, parsed.context)
        assertEquals(65, parsed.identity.size)
    }
    @Test fun duplicateUnknownExpiredLongLifetimeAndWrongTransportFailClosed() {
        for (uri in listOf(offer()+"&host=other", offer()+"&future=1", offer(1000), offer(1121),
            offer().replace("transport=nearby", "transport=lan"), offer().replace("version=1", "version=2"),
            offer()+"#token", offer().replace("galaxybridge://pair", "galaxybridge://other"))) {
            assertThrows(IllegalArgumentException::class.java) { NearbyPairingOffer.parse(uri, 1_000_000) }
        }
    }
}
