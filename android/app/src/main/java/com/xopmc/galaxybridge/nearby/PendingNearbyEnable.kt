package com.xopmc.galaxybridge.nearby

internal class NearbyEnableDelivery(val offer: String? = null, val expired: Boolean = false)

/** Memory-only ownership; the Activity's ViewModel retains it across recreation. */
internal class PendingNearbyEnable {
    var requested = false
        private set
    private var offer: String? = null

    fun request(offer: String? = null) {
        requested = true
        if (offer != null) this.offer = offer
    }

    fun complete(nowMillis: Long): NearbyEnableDelivery? {
        if (!requested) return null
        val candidate = offer
        cancel()
        if (candidate == null) return NearbyEnableDelivery()
        return if (runCatching { NearbyPairingOffer.parse(candidate, nowMillis) }.isSuccess) {
            NearbyEnableDelivery(offer = candidate)
        } else NearbyEnableDelivery(expired = true)
    }

    fun cancel() { requested = false; offer = null }
}
