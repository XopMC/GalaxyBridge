package com.xopmc.galaxybridge.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import com.xopmc.galaxybridge.core.P256Keys
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyFactory
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.security.auth.x500.X500Principal

class DeviceIdentityStore {
    private val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    fun keyPair(): KeyPair {
        val existing = keyStore.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry
        if (existing != null && supportsTlsSigning(existing)) {
            return KeyPair(existing.certificate.publicKey, existing.privateKey)
        }
        if (existing != null) keyStore.deleteEntry(ALIAS)

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
        generator.initialize(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                .setCertificateSubject(X500Principal("CN=GalaxyBridge Android Identity"))
                .setCertificateSerialNumber(BigInteger.ONE)
                .setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000L))
                .setCertificateNotAfter(Date(System.currentTimeMillis() + 10L * 365 * 86_400_000L))
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKeyPair()
    }

    private fun supportsTlsSigning(entry: KeyStore.PrivateKeyEntry): Boolean = runCatching {
        val keyInfo = KeyFactory.getInstance(entry.privateKey.algorithm, KEYSTORE)
            .getKeySpec(entry.privateKey, KeyInfo::class.java)
        KeyProperties.DIGEST_NONE in keyInfo.digests
    }.getOrDefault(false)

    fun fingerprint(): ByteArray = MessageDigest.getInstance("SHA-256").digest(publicKeyX963())

    fun publicKeyX963(): ByteArray = P256Keys.x963Representation(keyPair().public)

    fun certificateSha256(): ByteArray = MessageDigest.getInstance("SHA-256").digest(
        (keyStore.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry).certificate.encoded,
    )

    fun privateKeyEntry(): KeyStore.PrivateKeyEntry {
        keyPair()
        return keyStore.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry
    }

    fun signNonce(nonce: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(keyPair().private)
        update(nonce)
        sign()
    }

    fun revoke() {
        keyStore.deleteEntry(ALIAS)
    }

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "com.xopmc.galaxybridge.identity.p256"
    }
}

fun ByteArray.shortFingerprint(): String =
    take(8).joinToString(":") { byte -> "%02X".format(byte) }
