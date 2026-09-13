package com.xopmc.galaxybridge.core

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.ECParameterSpec

object P256Keys {
    const val X963_LENGTH = 65

    fun x963Representation(publicKey: PublicKey): ByteArray {
        val ecKey = publicKey as? ECPublicKey ?: throw IllegalArgumentException("not an EC public key")
        return byteArrayOf(0x04) + fixedUnsigned(ecKey.w.affineX) + fixedUnsigned(ecKey.w.affineY)
    }

    fun publicKey(x963: ByteArray): PublicKey {
        require(x963.size == X963_LENGTH && x963[0] == 0x04.toByte()) { "invalid P-256 X9.63 key" }
        val parameters = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec("secp256r1"))
        }.getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(
            BigInteger(1, x963.copyOfRange(1, 33)),
            BigInteger(1, x963.copyOfRange(33, 65)),
        )
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
    }

    private fun fixedUnsigned(value: BigInteger): ByteArray {
        val encoded = value.toByteArray()
        val unsigned = if (encoded.size == 33 && encoded[0] == 0.toByte()) encoded.copyOfRange(1, 33) else encoded
        require(unsigned.size <= 32)
        return ByteArray(32 - unsigned.size) + unsigned
    }
}

object PairingTranscript {
    private val domain = "GalaxyBridge/Pairing/v1".encodeToByteArray()
    private val requestDomain = "GalaxyBridge/PairingRequest/v1".encodeToByteArray()
    private val commitDomain = "GalaxyBridge/PairingCommit/v1".encodeToByteArray()
    private val commitAcknowledgementDomain = "GalaxyBridge/PairingCommitAck/v1".encodeToByteArray()

    fun makeRequest(
        token: ByteArray,
        clientNonce: ByteArray,
        macPublicKey: ByteArray,
        displayName: ByteArray,
    ): ByteArray = encode(listOf(requestDomain, token, clientNonce, macPublicKey, displayName))

    fun make(
        token: ByteArray,
        clientNonce: ByteArray,
        serverNonce: ByteArray,
        macPublicKey: ByteArray,
        androidPublicKey: ByteArray,
    ): ByteArray {
        return encode(listOf(domain, token, clientNonce, serverNonce, macPublicKey, androidPublicKey))
    }

    fun makeCommit(
        token: ByteArray,
        clientNonce: ByteArray,
        serverNonce: ByteArray,
        macPublicKey: ByteArray,
        androidPublicKey: ByteArray,
        hostId: String,
        deviceId: String,
        sessionId: String,
    ): ByteArray = encode(
        listOf(
            commitDomain,
            token,
            clientNonce,
            serverNonce,
            macPublicKey,
            androidPublicKey,
            hostId.encodeToByteArray(),
            deviceId.encodeToByteArray(),
            sessionId.encodeToByteArray(),
        ),
    )

    fun makeCommitAcknowledgement(
        commitTranscript: ByteArray,
        commitSignature: ByteArray,
    ): ByteArray = encode(listOf(commitAcknowledgementDomain, commitTranscript, commitSignature))

    private fun encode(fields: List<ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { writer ->
            fields.forEach { field ->
                writer.writeInt(field.size)
                writer.write(field)
            }
        }
        return output.toByteArray()
    }

    fun verify(signatureDer: ByteArray, transcript: ByteArray, publicKeyX963: ByteArray): Boolean =
        runCatching {
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(P256Keys.publicKey(publicKeyX963))
                update(transcript)
                verify(signatureDer)
            }
        }.getOrDefault(false)
}

object SessionAuthenticationTranscript {
    private val domain = "GalaxyBridge/SessionAuthentication/v1".encodeToByteArray()

    fun make(
        deviceId: String,
        sessionId: String,
        nonce: ByteArray,
        timestampUnixSeconds: Long,
        identityPublicKey: ByteArray,
    ): ByteArray {
        val timestamp = ByteArrayOutputStream().also { output ->
            DataOutputStream(output).use { it.writeLong(timestampUnixSeconds) }
        }.toByteArray()
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { writer ->
            listOf(
                domain,
                deviceId.encodeToByteArray(),
                sessionId.encodeToByteArray(),
                nonce,
                timestamp,
                identityPublicKey,
            ).forEach { field ->
                writer.writeInt(field.size)
                writer.write(field)
            }
        }
        return output.toByteArray()
    }
}
