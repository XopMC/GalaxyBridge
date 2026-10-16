package com.xopmc.galaxybridge.nearby

enum class NearbyLinkKind { P2P_OWNER, P2P_JOIN, LOCAL_HOTSPOT, LOCAL_WIFI_JOIN }
internal object NearbyRadioPolicy {
    fun rejection(staConnected: Boolean, kind: NearbyLinkKind, p2pStaVerified: Boolean, staHotspotSupported: Boolean): String? = when {
        !staConnected -> null
        kind == NearbyLinkKind.LOCAL_HOTSPOT && !staHotspotSupported -> "sta_hotspot_concurrency_unsupported"
        kind == NearbyLinkKind.LOCAL_WIFI_JOIN && !p2pStaVerified -> "sta_local_wifi_concurrency_unsupported"
        kind != NearbyLinkKind.LOCAL_HOTSPOT && !p2pStaVerified -> "sta_p2p_concurrency_unverified"
        else -> null
    }
}
internal data class NearbyGroupIdentity(val networkName: String, val interfaceName: String, val networkId: Int, val groupOwner: Boolean) {
    fun matches(other: NearbyGroupIdentity) = this == other
}

/** Ownership can only be established for the requested group/role, then never reassigned. */
internal class NearbyGroupOwnership(private val requestedName: String, private val requestedOwner: Boolean) {
    var identity: NearbyGroupIdentity? = null
        private set
    fun observe(group: NearbyGroupIdentity): Boolean {
        if (group.networkName != requestedName || group.groupOwner != requestedOwner || group.interfaceName.isBlank()) return false
        if (identity == null) identity = group
        return requireNotNull(identity).matches(group)
    }
    fun mayRemove(group: NearbyGroupIdentity): Boolean = identity?.matches(group) == true
}
