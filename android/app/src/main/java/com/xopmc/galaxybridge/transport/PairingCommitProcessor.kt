package com.xopmc.galaxybridge.transport

import com.google.protobuf.ByteString
import com.xopmc.galaxybridge.core.PairingTranscript
import com.xopmc.galaxybridge.protocol.v1.PairingCommit
import com.xopmc.galaxybridge.protocol.v1.PairingCommitAck

internal data class PairingCommitCandidate(
    val token: ByteArray,
    val clientNonce: ByteArray,
    val serverNonce: ByteArray,
    val macPublicKey: ByteArray,
    val androidPublicKey: ByteArray,
    val hostId: String,
    val deviceId: String,
    val sessionId: String,
    val expiresAtMillis: Long,
) {
    fun commitTranscript(): ByteArray = PairingTranscript.makeCommit(
        token = token,
        clientNonce = clientNonce,
        serverNonce = serverNonce,
        macPublicKey = macPublicKey,
        androidPublicKey = androidPublicKey,
        hostId = hostId,
        deviceId = deviceId,
        sessionId = sessionId,
    )
}

internal data class PairingCommitAcceptance(
    val acknowledgement: PairingCommitAck,
    val acknowledgementTranscript: ByteArray,
)

/** Verifies and commits one pending pairing candidate without exposing it as trusted early. */
internal class PairingCommitProcessor(
    private val candidate: PairingCommitCandidate,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private var acceptedCommit: ByteArray? = null
    private var acceptedResult: PairingCommitAcceptance? = null

    val isCommitted: Boolean
        get() = acceptedResult != null

    @Synchronized
    fun accept(
        commit: PairingCommit,
        promote: () -> Boolean,
        signAcknowledgement: (ByteArray) -> ByteArray,
    ): PairingCommitAcceptance? {
        if (nowMillis() >= candidate.expiresAtMillis) return null
        if (commit.hostId != candidate.hostId ||
            commit.deviceId != candidate.deviceId ||
            commit.sessionId != candidate.sessionId
        ) return null

        val encodedCommit = commit.toByteArray()
        acceptedResult?.let { cached ->
            return if (acceptedCommit?.contentEquals(encodedCommit) == true) cached else null
        }

        val commitTranscript = candidate.commitTranscript()
        if (!PairingTranscript.verify(
                commit.transcriptSignature.toByteArray(),
                commitTranscript,
                candidate.macPublicKey,
            )
        ) return null

        val acknowledgementTranscript = PairingTranscript.makeCommitAcknowledgement(
            commitTranscript = commitTranscript,
            commitSignature = commit.transcriptSignature.toByteArray(),
        )
        val acknowledgementSignature = signAcknowledgement(acknowledgementTranscript)
        val acknowledgement = PairingCommitAck.newBuilder()
            .setCommitted(true)
            .setHostId(candidate.hostId)
            .setDeviceId(candidate.deviceId)
            .setSessionId(candidate.sessionId)
            .setTranscriptSignature(ByteString.copyFrom(acknowledgementSignature))
            .build()
        // The callback must durably replace the pending candidate with the paired identity
        // in one atomic storage transaction. The prebuilt acknowledgement is not returned
        // or emitted if that transaction fails.
        if (!promote()) return null
        return PairingCommitAcceptance(acknowledgement, acknowledgementTranscript).also {
            acceptedCommit = encodedCommit
            acceptedResult = it
        }
    }
}
