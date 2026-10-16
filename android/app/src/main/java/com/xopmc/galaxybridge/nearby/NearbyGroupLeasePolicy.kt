package com.xopmc.galaxybridge.nearby

/** One phone owns one group. The paired Mac must explicitly assume its lifetime. */
internal class NearbyGroupLeasePolicy {
    private data class Lease(val peer: String, val connection: String, val id: String, var started: Long,
        var deadline: Long, var bootstrapOpen: Boolean = true, var established: Boolean = false)
    private var lease: Lease? = null
    val leaseID: String get() = lease?.id.orEmpty()
    val peerID: String get() = lease?.peer.orEmpty()
    val established: Boolean get() = lease?.established == true
    fun create(peer: String, connection: String?, id: String, now: Long): Boolean {
        if (lease != null || peer.isBlank() || connection.isNullOrBlank() || id.isBlank() ||
            now < 0 || now > Long.MAX_VALUE - LEASE_MILLIS) return false
        lease = Lease(peer, connection, id, now, now + LEASE_MILLIS)
        return true
    }
    fun permits(peer: String, id: String, connection: String?, now: Long): Boolean = lease?.let {
        it.peer == peer && it.id == id && !expired(it, now) &&
            (it.established || connection == null || (connection == it.connection && it.bootstrapOpen))
    } == true
    fun confirm(peer: String, id: String, connection: String?, now: Long): Boolean {
        if (!permits(peer, id, connection, now) || now > Long.MAX_VALUE - LEASE_MILLIS) return false
        requireNotNull(lease).apply { established = true; started = now; deadline = now + LEASE_MILLIS }
        return true
    }
    fun bootstrapClosed(connection: String) {
        lease?.takeIf { it.connection == connection }?.bootstrapOpen = false
    }
    private fun expired(value: Lease, now: Long) = now < value.started || now >= value.deadline
    fun expiredLease(now: Long): String? = lease?.takeIf { expired(it, now) }?.id
    fun clear(id: String): Boolean {
        if (lease?.id != id) return false
        lease = null
        return true
    }
    companion object { const val LEASE_MILLIS = 45_000L }
}
