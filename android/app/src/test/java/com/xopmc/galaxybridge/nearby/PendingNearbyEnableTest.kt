package com.xopmc.galaxybridge.nearby

import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.xopmc.galaxybridge.NearbyEnableViewModel
import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class PendingNearbyEnableTest {
    private fun offer(): String {
        fun encoded(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        val identity = ByteArray(65).apply { this[0] = 4 }
        return "galaxybridge://pair?transport=nearby&version=1&host=69830b65-6352-4b3a-8a21-70bcda45787e" +
            "&identity=${encoded(identity)}&token=${encoded(ByteArray(32) { 1 })}&context=${encoded(ByteArray(32) { 2 })}" +
            "&expires=1120&sid=d5e1590c-47fb-4d73-9ac2-45988ba0a876"
    }

    @Test fun recreatedConsumerDeliversRetainedUnexpiredOfferExactlyOnce() {
        val retainedStore = ViewModelStore()
        try {
            val firstConsumer = ViewModelProvider(retainedStore, ViewModelProvider.NewInstanceFactory())
            firstConsumer[NearbyEnableViewModel::class.java].pending.request(offer())
            // A recreated Activity has a new provider over the retained ViewModelStore.
            val recreatedConsumer = ViewModelProvider(retainedStore, ViewModelProvider.NewInstanceFactory())
            val pending = recreatedConsumer[NearbyEnableViewModel::class.java].pending
            assertEquals(offer(), pending.complete(nowMillis = 1_010_000)?.offer)
            assertNull(pending.complete(nowMillis = 1_010_000))
            assertFalse(pending.requested)
        } finally { retainedStore.clear() }
    }

    @Test fun expiredOfferIsRejectedAtDeliveryAndCannotBeReplayed() {
        val pending = PendingNearbyEnable()
        pending.request(offer())
        assertTrue(pending.complete(nowMillis = 1_120_000)?.expired == true)
        assertNull(pending.complete(nowMillis = 1_120_001))
    }

    @Test fun permissionOnlyEnableStillCompletesWithoutAnOffer() {
        val pending = PendingNearbyEnable()
        pending.request()
        val result = pending.complete(nowMillis = 1_000_000)
        assertNotNull(result)
        assertNull(result?.offer)
        assertFalse(result?.expired ?: true)
    }

    @Test fun cancellingDropsTheOfferAndThePendingEnable() {
        val pending = PendingNearbyEnable()
        pending.request(offer())
        pending.cancel()
        assertFalse(pending.requested)
        assertNull(pending.complete(nowMillis = 1_000_000))
    }
}
