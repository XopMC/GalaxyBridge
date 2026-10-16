package com.xopmc.galaxybridge.transport

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import com.google.protobuf.ByteString
import com.xopmc.galaxybridge.core.PairingTranscript
import com.xopmc.galaxybridge.nearby.NearbyGattSession
import com.xopmc.galaxybridge.nearby.NearbyGroupLeasePolicy
import com.xopmc.galaxybridge.nearby.NearbyLinkKind
import com.xopmc.galaxybridge.nearby.NearbyNetworkController
import com.xopmc.galaxybridge.nearby.NearbyNetworkOffer
import com.xopmc.galaxybridge.nearby.NearbyPairingOffer
import com.xopmc.galaxybridge.protocol.v1.DirectLinkDescriptor
import com.xopmc.galaxybridge.protocol.v1.DirectLinkRequest
import com.xopmc.galaxybridge.protocol.v1.DirectLinkStatus
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.PairingResponse
import com.xopmc.galaxybridge.security.DeviceIdStore
import com.xopmc.galaxybridge.security.DeviceIdentityStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

/** BLE grants no trust by itself. Network operations require paired identity or a committed QR proof. */
class NearbyBootstrapCoordinator(private val context: Context, private val isForegroundOwner: () -> Boolean,
    private val companionPort: () -> Int) : AutoCloseable {
    private val lock = Any()
    private val preferences = context.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    private val identity = DeviceIdentityStore()
    private val deviceID = DeviceIdStore.getOrCreate(context)
    private val groupLifetime = NearbyGroupLeasePolicy()
    private val deadlineHandler = Handler(Looper.getMainLooper())
    private var groupExpiry: Runnable? = null
    private val groupLease: String get() = groupLifetime.leaseID
    private val groupPeer: String get() = groupLifetime.peerID
    private var groupOwnerID = ""
    private var currentOffer: NearbyNetworkOffer? = null
    private var error = ""
    private var fallbackAttempted = false
    private var pendingQR: NearbyPairingOffer? = null
    private var pendingQRConnection: String? = null
    private var closed = false
    private val network = NearbyNetworkController(context, isForegroundOwner, { offer -> synchronized(lock) {
        expireGroupLocked()
        if (!closed && groupLease.isNotEmpty()) { currentOffer = offer; error = "" }
    } }, { reason -> synchronized(lock) {
        if (!fallbackAttempted && groupOwnerID == deviceID && reason in setOf("wifi_direct_unavailable", "wifi_direct_start_failed_1", "sta_p2p_concurrency_unverified")) {
            fallbackAttempted = true
            networkFallback()
        } else error = reason
    } })

    private fun networkFallback() { network.startLocalOnlyHotspot() }
    fun installOfflineOffer(uri: String) = synchronized(lock) {
        check(!closed && isForegroundOwner())
        pendingQR = NearbyPairingOffer.parse(uri, System.currentTimeMillis())
        pendingQRConnection = null
    }
    fun cancelOfflineOffer() = synchronized(lock) { pendingQR = null; pendingQRConnection = null }

    fun handleAuthenticated(peerID: String, request: DirectLinkRequest, bootstrapConnectionID: String? = null): Envelope = synchronized(lock) {
        check(!closed && isForegroundOwner()) { "foreground_owner_required" }
        check(preferences.getBoolean("nearby_enabled", false)) { "nearby_disabled" }
        check(preferences.getString("paired_host_id", null) == peerID) { "nearby_unpaired_host" }
        require(request.requestId.length in 1..128)
        expireGroupLocked()
        if (request.confirmed) {
            if (!request.enabled || currentOffer == null || error.isNotEmpty() ||
                !groupLifetime.confirm(peerID, request.groupLeaseId, bootstrapConnectionID, SystemClock.elapsedRealtime())) {
                return@synchronized status(request.requestId, "failed", "nearby_confirmation_invalid")
            }
            armGroupExpiryLocked(groupLease)
            return@synchronized status(request.requestId, "established")
        }
        if (!request.enabled) {
            if (groupLease.isNotEmpty()) {
                if (request.groupLeaseId != groupLease || groupPeer != peerID) return@synchronized status(request.requestId, "failed", "nearby_lease_unknown")
                stopGroupLocked()
            }
            return@synchronized status(request.requestId, "disabled")
        }
        if (request.groupLeaseId.isNotEmpty()) {
            if (!groupLifetime.permits(peerID, request.groupLeaseId, bootstrapConnectionID, SystemClock.elapsedRealtime()))
                return@synchronized status(request.requestId, "failed", "nearby_lease_unknown")
            val offer = currentOffer
            return@synchronized if (offer != null && error.isEmpty()) descriptor(offer) else status(request.requestId, if (error.isEmpty()) "pending" else "failed", error)
        }
        if (groupLease.isNotEmpty()) return@synchronized status(request.requestId, "failed", "nearby_group_already_leased")
        if (!groupLifetime.create(peerID, bootstrapConnectionID, UUID.randomUUID().toString(), SystemClock.elapsedRealtime()))
            return@synchronized status(request.requestId, "failed", "nearby_bootstrap_required")
        currentOffer = null; error = ""; fallbackAttempted = false
        armGroupExpiryLocked(groupLease)
        groupOwnerID = if (request.hasJoin()) request.join.ownerDeviceId else deviceID
        if (request.hasJoin()) {
            require(request.join.mode in setOf("p2p", "local_only_hotspot")) { "unsupported_shared_group" }
            if (request.join.mode == "p2p") network.joinGroup(request.join.networkName, request.join.passphrase)
            else network.joinLocalOnlyHotspot(request.join.networkName, request.join.passphrase, request.join.ownerAddress)
        } else {
            val random = SecureRandom()
            fun hex(count: Int) = ByteArray(count).also(random::nextBytes).joinToString("") { "%02x".format(it) }
            network.createGroup("DIRECT-${hex(1)}-GB${hex(3)}", hex(16))
        }
        status(request.requestId, "pending")
    }

    private fun descriptor(offer: NearbyNetworkOffer): Envelope {
        val port = companionPort()
        check(port in 1..65535) { "companion_listener_unavailable" }
        val descriptor = DirectLinkDescriptor.newBuilder().setGroupLeaseId(groupLease).setOwnerDeviceId(groupOwnerID)
            .setGeneration(offer.generation).setNetworkName(offer.networkName).setPassphrase(offer.passphrase)
            .setOwnerAddress(offer.ownerAddress).setCompanionPort(port)
            .setMode(if (offer.kind == NearbyLinkKind.LOCAL_HOTSPOT || offer.kind == NearbyLinkKind.LOCAL_WIFI_JOIN) "local_only_hotspot" else "p2p")
            .setInterfaceName(offer.interfaceName).setDeviceId(deviceID)
            .setDeviceAddress(offer.localAddresses.firstOrNull() ?: offer.ownerAddress)
            .setTlsCertificateSha256(ByteString.copyFrom(identity.certificateSha256()))
            .setIdentityPublicKey(ByteString.copyFrom(identity.publicKeyX963())).setDisplayName(Build.MODEL)
        return base().setDirectLinkDescriptor(descriptor).build()
    }
    private fun status(requestID: String, state: String, reason: String = "") = base().setDirectLinkStatus(
        DirectLinkStatus.newBuilder().setRequestId(requestID).setGroupLeaseId(groupLease).setState(state)
            .setErrorCode(reason).setUpstreamWifiPreserved(currentOffer?.upstreamWifiPreserved == true)).build()
    private fun base() = Envelope.newBuilder().setProtocolMajor(1).setProtocolMinor(0).setDeviceId(deviceID)
    private fun cancelGroupExpiryLocked() { groupExpiry?.let(deadlineHandler::removeCallbacks); groupExpiry = null }
    private fun expireGroupLocked() {
        if (groupLifetime.expiredLease(SystemClock.elapsedRealtime()) != null) stopGroupLocked()
    }
    private fun armGroupExpiryLocked(expectedLease: String) {
        cancelGroupExpiryLocked()
        val check = object : Runnable {
            override fun run() = synchronized(lock) {
                if (closed || groupLease != expectedLease) return@synchronized
                expireGroupLocked()
                // elapsedRealtime includes sleep. Wake-up never extends the
                // fixed deadline; at most one awake second precedes recovery.
                if (groupLease == expectedLease) deadlineHandler.postDelayed(this, 1_000)
                Unit
            }
        }
        groupExpiry = check
        deadlineHandler.postDelayed(check, 1_000)
    }
    private fun stopGroupLocked() {
        cancelGroupExpiryLocked()
        network.stop(currentOffer?.leaseID)
        groupLifetime.clear(groupLease)
        currentOffer = null; groupOwnerID = ""; error = ""
    }
    fun disable() = synchronized(lock) { stopGroupLocked(); cancelOfflineOffer() }

    fun newSession(connectionID: String): NearbyGattSession = object : NearbyGattSession {
        private var session: NearbyBootstrapCrypto.Session? = null
        private var peerID = ""
        private var trusted = false
        private var authenticatedKey = ByteArray(0)
        private var processor: PairingCommitProcessor? = null
        private var candidate: PairingCommitCandidate? = null
        private var sessionClosed = false
        private var encryptedPeerVerified = false
        override val isAuthenticated: Boolean get() = !sessionClosed && trusted && encryptedPeerVerified
        override fun receive(frame: ByteArray): List<ByteArray> = synchronized(lock) {
            check(!closed && !sessionClosed && isForegroundOwner())
            if (session == null) {
                val remote = NearbyBootstrapCrypto.Hello.decode(frame)
                require(remote.role == 0)
                val qr = pendingQR?.takeIf { it.expiresAtMillis > System.currentTimeMillis() && it.hostID == remote.deviceID }
                val storedKey = if (preferences.getString("paired_host_id", null) == remote.deviceID)
                    preferences.getString("paired_mac_key", null)?.let { Base64.decode(it, Base64.DEFAULT) } else null
                val expected = qr?.identity ?: storedKey ?: error("nearby_unpaired_host")
                if (qr != null) {
                    check(pendingQRConnection == null || pendingQRConnection == connectionID)
                    require(MessageDigest.isEqual(qr.context, remote.context))
                }
                remote.validate(expected)
                val agreement = NearbyBootstrapCrypto.Agreement(1, deviceID, remote.context, identity.keyPair())
                val hello = agreement.hello()
                session = agreement.complete(remote, expected, qr?.token)
                peerID = remote.deviceID
                authenticatedKey = remote.identity.clone()
                trusted = qr == null
                if (qr == null) return@synchronized listOf(hello.encode())
                pendingQRConnection = connectionID
                val pairing = PairingCommitCandidate(qr.token, remote.nonce, hello.nonce, qr.identity,
                    hello.identity, qr.hostID, deviceID, qr.sessionID, qr.expiresAtMillis)
                candidate = pairing; processor = PairingCommitProcessor(pairing)
                val response = PairingResponse.newBuilder().setAccepted(true).setIdentityPublicKey(ByteString.copyFrom(hello.identity))
                    .setServerNonce(ByteString.copyFrom(hello.nonce)).setTlsCertificateSha256(ByteString.copyFrom(identity.certificateSha256()))
                    .setDisplayName(Build.MODEL).setDeviceId(deviceID)
                    .setTranscriptSignature(ByteString.copyFrom(identity.signNonce(PairingTranscript.make(qr.token, remote.nonce, hello.nonce, qr.identity, hello.identity))))
                return@synchronized listOf(hello.encode(), requireNotNull(session).seal(base().setSessionId(qr.sessionID).setPairingResponse(response).build().toByteArray()))
            }
            val crypto = requireNotNull(session)
            val request = Envelope.parseFrom(crypto.open(frame))
            encryptedPeerVerified = true
            require(request.protocolMajor == 1 && request.deviceId == peerID && request.sessionId.length in 1..128)
            val response = if (!trusted) {
                val pairing = requireNotNull(candidate)
                require(request.hasPairingCommit() && request.sessionId == pairing.sessionId)
                check(pendingQR?.sessionID == pairing.sessionId && pendingQRConnection == connectionID)
                val accepted = requireNotNull(processor).accept(request.pairingCommit, promote = {
                    val result = preferences.edit().putString("paired_host_id", pairing.hostId)
                        .putString("paired_mac_key", Base64.encodeToString(pairing.macPublicKey, Base64.NO_WRAP))
                        .putLong("paired_at", System.currentTimeMillis()).remove("pending_pairing").commit()
                    if (result) { pendingQR = null; pendingQRConnection = null; PairingStateBus.publishSuccess() }
                    result
                }, signAcknowledgement = identity::signNonce) ?: error("nearby_pairing_commit_rejected")
                trusted = true
                base().setSessionId(pairing.sessionId).setPairingCommitAck(accepted.acknowledgement).build()
            } else {
                // Recheck revocation for every encrypted operation, not only the initial Hello.
                check(preferences.getString("paired_host_id", null) == peerID)
                val stored = preferences.getString("paired_mac_key", null)?.let { Base64.decode(it, Base64.DEFAULT) }
                check(stored != null && MessageDigest.isEqual(stored, authenticatedKey))
                if (request.hasPairingCommit() && processor?.isCommitted == true) {
                    val accepted = requireNotNull(processor).accept(request.pairingCommit, { false }, identity::signNonce)
                        ?: error("nearby_pairing_commit_rejected")
                    return@synchronized listOf(crypto.seal(base().setSessionId(request.sessionId)
                        .setPairingCommitAck(accepted.acknowledgement).build().toByteArray()))
                }
                require(request.hasDirectLinkRequest())
                handleAuthenticated(peerID, request.directLinkRequest, connectionID).toBuilder().setSessionId(request.sessionId).setMessageId(request.messageId + 1).build()
            }
            listOf(crypto.seal(response.toByteArray()))
        }
        override fun close() = synchronized(lock) {
            sessionClosed = true; session = null
            groupLifetime.bootstrapClosed(connectionID)
            expireGroupLocked()
            if (pendingQRConnection == connectionID) pendingQRConnection = null
        }
    }
    override fun close() = synchronized(lock) { closed = true; disable(); network.close() }
}
