package com.xopmc.galaxybridge.internet

import java.util.UUID

enum class UpstreamKind { WIFI, CELLULAR, VPN, OTHER }
internal data class UpstreamCandidate(val handle: Long, val kind: UpstreamKind, val validated: Boolean)
internal object UpstreamSelectionPolicy {
    fun select(candidates: List<UpstreamCandidate>, previous: Long?, requiredVpn: Long? = null, defaultNetworkKnown: Boolean = true): UpstreamCandidate? {
        if (!defaultNetworkKnown) return null
        // A VPN applying to this app is mandatory, even when a physical network
        // looks faster. A missing/unvalidated VPN must never become a bypass.
        if (requiredVpn != null) return candidates.firstOrNull {
            it.handle == requiredVpn && it.kind == UpstreamKind.VPN && it.validated
        }
        val usable = candidates.filter { it.validated && it.kind in setOf(UpstreamKind.WIFI, UpstreamKind.CELLULAR) }
        val preferred = usable.filter { it.kind == UpstreamKind.WIFI }.ifEmpty { usable.filter { it.kind == UpstreamKind.CELLULAR } }
        return preferred.firstOrNull { it.handle == previous } ?: preferred.minByOrNull { it.handle }
    }
    fun requiresRetirement(previous: UpstreamCandidate?, next: UpstreamCandidate?): Boolean =
        previous?.handle != next?.handle && (previous?.kind == UpstreamKind.VPN || next?.kind == UpstreamKind.VPN)
}

data class InternetLease(val id: String, val peerID: String, val sessionID: String, val expiresAtMillis: Long)
internal class InternetLeaseRegistry(private val now: () -> Long = System::currentTimeMillis,
    private val onPeerRotation: (String) -> Unit = {}) {
    private val leases = linkedMapOf<String, InternetLease>()
    @Synchronized fun enable(peerID: String, sessionID: String, durationMillis: Long, requestedID: String? = null): InternetLease {
        require(peerID.isNotBlank() && peerID.length <= 256 && sessionID.isNotBlank() && sessionID.length <= 128 && durationMillis in 1..3_600_000)
        val instant = now()
        val id = requestedID ?: UUID.randomUUID().toString()
        require(runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false))
        val existing = leases[id]
        if (existing != null && existing.peerID == peerID && existing.sessionID == sessionID && existing.expiresAtMillis > instant) {
            // Status/renew is not a new user activation: retain sockets and native credentials.
            return existing.copy(expiresAtMillis = instant + durationMillis).also { leases[id] = it }
        }
        require(existing == null || existing.expiresAtMillis <= instant || existing.peerID == peerID)
        check(leases.values.count { it.expiresAtMillis > instant && it.peerID != peerID } < 2) { "gateway_peer_limit" }
        onPeerRotation(peerID)
        leases.values.filter { it.expiresAtMillis <= instant || it.peerID == peerID }.map { it.id }.forEach(leases::remove)
        return InternetLease(id, peerID, sessionID, instant + durationMillis).also { leases[id] = it }
    }
    @Synchronized fun admits(peerID: String, sessionID: String, leaseID: String): Boolean = leases[leaseID]?.let {
        it.peerID == peerID && it.sessionID == sessionID && it.expiresAtMillis > now()
    } == true
    @Synchronized fun renew(peerID: String, sessionID: String, durationMillis: Long = 3_600_000) {
        require(durationMillis in 1..3_600_000)
        leases.values.filter { it.peerID == peerID && it.sessionID == sessionID && it.expiresAtMillis > now() }.forEach {
            leases[it.id] = it.copy(expiresAtMillis = now() + durationMillis)
        }
    }
    @Synchronized fun revoke(peerID: String, sessionID: String) {
        leases.values.filter { it.peerID == peerID && it.sessionID == sessionID }.map { it.id }.forEach(leases::remove)
    }
    @Synchronized fun revokePeer(peerID: String) {
        leases.values.filter { it.peerID == peerID }.map { it.id }.forEach(leases::remove)
    }
    @Synchronized fun clear() = leases.clear()
    @Synchronized fun hasActive(): Boolean = leases.values.any { it.expiresAtMillis > now() }
}
