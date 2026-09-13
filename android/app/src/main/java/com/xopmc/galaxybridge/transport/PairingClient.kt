package com.xopmc.galaxybridge.transport

import android.content.Context
import android.os.Build
import android.util.Base64
import android.util.Log
import androidx.core.content.edit
import com.google.protobuf.ByteString
import com.xopmc.galaxybridge.core.PairingTranscript
import com.xopmc.galaxybridge.core.PairingUriCodec
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.PairingResponse
import com.xopmc.galaxybridge.security.DeviceIdentityStore
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

class PairingClient(private val context: Context) {
    private val identity = DeviceIdentityStore()

    fun pair(uri: String): Boolean {
        val qr = PairingUriCodec.decode(uri, System.currentTimeMillis() / 1_000)
        for ((index, address) in qr.addresses.withIndex()) {
            val succeeded = runCatching {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(address, qr.port), CONNECT_TIMEOUT_MS)
                    socket.soTimeout = SOCKET_TIMEOUT_MS
                    val input = DataInputStream(socket.inputStream)
                    val output = DataOutputStream(socket.outputStream)
                    val length = input.readInt()
                    require(length in 1..MAX_CONTROL_FRAME)
                    val bytes = ByteArray(length)
                    input.readFully(bytes)
                    val envelope = Envelope.parseFrom(bytes)
                    require(envelope.hasPairingRequest())
                    val request = envelope.pairingRequest
                    val macKey = request.identityPublicKey.toByteArray()
                    val token = request.oneTimeToken.toByteArray()
                    val clientNonce = request.clientNonce.toByteArray()
                    val requestTranscript = PairingTranscript.makeRequest(
                        token,
                        clientNonce,
                        macKey,
                        request.displayName.toByteArray(Charsets.UTF_8),
                    )
                    require(macKey.size == 65)
                    require(clientNonce.size == 32)
                    require(MessageDigest.isEqual(token, qr.token))
                    require(MessageDigest.isEqual(MessageDigest.getInstance("SHA-256").digest(macKey), qr.publicKeyFingerprint))
                    require(PairingTranscript.verify(request.transcriptSignature.toByteArray(), requestTranscript, macKey))

                    val localDeviceId = deviceId()
                    val serverNonce = ByteArray(32).also(SecureRandom()::nextBytes)
                    val androidKey = identity.publicKeyX963()
                    val transcript = PairingTranscript.make(token, clientNonce, serverNonce, macKey, androidKey)
                    val response = PairingResponse.newBuilder()
                        .setAccepted(true)
                        .setIdentityPublicKey(ByteString.copyFrom(androidKey))
                        .setServerNonce(ByteString.copyFrom(serverNonce))
                        .setTranscriptSignature(ByteString.copyFrom(identity.signNonce(transcript)))
                        .setTlsCertificateSha256(ByteString.copyFrom(identity.certificateSha256()))
                        .setDisplayName("${Build.MANUFACTURER} ${Build.MODEL}")
                        .setDeviceId(localDeviceId)
                        .build()
                    val responseEnvelope = Envelope.newBuilder()
                        .setProtocolMajor(1)
                        .setProtocolMinor(0)
                        .setDeviceId(localDeviceId)
                        .setSessionId(envelope.sessionId)
                        .setMessageId(envelope.messageId + 1)
                        .setPairingResponse(response)
                        .build()
                    val candidate = PairingCommitCandidate(
                        token = token,
                        clientNonce = clientNonce,
                        serverNonce = serverNonce,
                        macPublicKey = macKey,
                        androidPublicKey = androidKey,
                        hostId = qr.hostId.toString(),
                        deviceId = localDeviceId,
                        sessionId = envelope.sessionId,
                        expiresAtMillis = qr.expiresAtEpochSeconds * 1_000,
                    )
                    val processor = PairingCommitProcessor(candidate)
                    writeEnvelope(output, responseEnvelope)
                    var acknowledgedAt = 0L
                    while (System.currentTimeMillis() < candidate.expiresAtMillis) {
                        val incoming = try {
                            readEnvelope(input)
                        } catch (_: SocketTimeoutException) {
                            if (processor.isCommitted &&
                                System.currentTimeMillis() - acknowledgedAt >= ACK_RETRY_WINDOW_MS
                            ) break
                            writeEnvelope(output, responseEnvelope)
                            continue
                        } catch (error: EOFException) {
                            // The Mac closes the one-time exchange immediately
                            // after it has verified our signed commit Ack. Once
                            // that Ack was flushed and local trust was promoted,
                            // EOF is successful completion rather than a reason
                            // to retry unrelated addresses from the same QR.
                            if (pairingEOFCompletes(processor.isCommitted, acknowledgedAt)) break
                            throw error
                        }
                        if (incoming.sessionId != candidate.sessionId) continue
                        if (incoming.hasPairingRequest()) {
                            writeEnvelope(output, responseEnvelope)
                            continue
                        }
                        if (!incoming.hasPairingCommit()) continue
                        val wasCommitted = processor.isCommitted
                        val accepted = processor.accept(
                            incoming.pairingCommit,
                            promote = { storePairing(candidate.hostId, macKey) },
                            signAcknowledgement = identity::signNonce,
                        ) ?: continue
                        val acknowledgement = Envelope.newBuilder()
                            .setProtocolMajor(1)
                            .setProtocolMinor(0)
                            .setDeviceId(localDeviceId)
                            .setSessionId(candidate.sessionId)
                            .setMessageId(incoming.messageId + 1)
                            .setPairingCommitAck(accepted.acknowledgement)
                            .build()
                        writeEnvelope(output, acknowledgement)
                        if (!wasCommitted) {
                            acknowledgedAt = System.currentTimeMillis()
                            PairingStateBus.publishSuccess()
                        }
                    }
                    require(processor.isCommitted) { "pairing commit was not completed" }
                }
                true
            }.onFailure { error ->
                Log.w(
                    TAG,
                    "Pairing endpoint ${index + 1}/${qr.addresses.size} failed (${error.javaClass.simpleName})",
                )
            }.getOrDefault(false)
            if (succeeded) return true
        }
        return false
    }

    private fun storePairing(hostId: String, macKey: ByteArray): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .remove(PENDING_PAIRING)
            .putString(PAIRED_MAC_KEY, Base64.encodeToString(macKey, Base64.NO_WRAP))
            .putString(PAIRED_HOST_ID, hostId)
            .putLong(PAIRED_AT, System.currentTimeMillis())
            .commit()

    private fun readEnvelope(input: DataInputStream): Envelope {
        val length = input.readInt()
        require(length in 1..MAX_CONTROL_FRAME)
        return Envelope.parseFrom(ByteArray(length).also(input::readFully))
    }

    private fun writeEnvelope(output: DataOutputStream, envelope: Envelope) {
        val encoded = envelope.toByteArray()
        output.writeInt(encoded.size)
        output.write(encoded)
        output.flush()
    }

    private fun deviceId(): String {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        return preferences.getString(DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            preferences.edit { putString(DEVICE_ID, it) }
        }
    }

    private companion object {
        const val PREFERENCES = "galaxybridge"
        const val PENDING_PAIRING = "pending_pairing"
        const val PAIRED_MAC_KEY = "paired_mac_key"
        const val PAIRED_HOST_ID = "paired_host_id"
        const val PAIRED_AT = "paired_at"
        const val DEVICE_ID = "device_id"
        const val MAX_CONTROL_FRAME = 8 * 1024 * 1024
        const val CONNECT_TIMEOUT_MS = 5_000
        const val SOCKET_TIMEOUT_MS = 1_000
        const val ACK_RETRY_WINDOW_MS = 3_000L
        const val TAG = "GalaxyBridgePairing"
    }
}

internal fun pairingEOFCompletes(isCommitted: Boolean, acknowledgementSentAtMillis: Long): Boolean =
    isCommitted && acknowledgementSentAtMillis > 0L
