package com.xopmc.galaxybridge.core

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.security.Signature

/** Canonical proof binding an ADB serial to a paired Android identity. */
object ADBBindingTranscript {
    private val domain = "GalaxyBridge/ADBBinding/v1".encodeToByteArray()

    fun make(
        hostId: String,
        adbSerial: String,
        nonce: ByteArray,
        androidPublicKey: ByteArray,
    ): ByteArray {
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { writer ->
            listOf(
                domain,
                hostId.encodeToByteArray(),
                adbSerial.encodeToByteArray(),
                nonce,
                androidPublicKey,
            ).forEach { field ->
                writer.writeInt(field.size)
                writer.write(field)
            }
        }
        return output.toByteArray()
    }

    fun verify(
        signatureDer: ByteArray,
        hostId: String,
        adbSerial: String,
        nonce: ByteArray,
        androidPublicKey: ByteArray,
    ): Boolean = runCatching {
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(P256Keys.publicKey(androidPublicKey))
            update(make(hostId, adbSerial, nonce, androidPublicKey))
            verify(signatureDer)
        }
    }.getOrDefault(false)
}
