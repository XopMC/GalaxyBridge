package com.xopmc.galaxybridge.storage

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal interface CacheRetentionDatabase {
    fun beginTransaction()
    fun deleteExpired(nowMillis: Long): Int
    fun setTransactionSuccessful()
    fun endTransaction()
}

internal class CacheRetentionMaintenance(
    private val clock: () -> Long = System::currentTimeMillis,
) {
    fun prune(database: CacheRetentionDatabase, nowMillis: Long = clock()): Int =
        inTransaction(database) { database.deleteExpired(nowMillis) }

    fun <T> pruneAndWrite(
        database: CacheRetentionDatabase,
        nowMillis: Long = clock(),
        write: () -> T,
    ): T = inTransaction(database) {
        database.deleteExpired(nowMillis)
        write()
    }

    private fun <T> inTransaction(database: CacheRetentionDatabase, operation: () -> T): T {
        database.beginTransaction()
        return try {
            operation().also { database.setTransactionSuccessful() }
        } finally {
            database.endTransaction()
        }
    }
}

data class CachedContent(
    val payload: ByteArray,
    val createdAtMillis: Long,
    val expiresAtMillis: Long,
)

class EncryptedContentCache(
    context: Context,
    private val clock: () -> Long = System::currentTimeMillis,
) : SQLiteOpenHelper(
    context.applicationContext,
    DATABASE_NAME,
    null,
    DATABASE_VERSION,
) {
    private val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
    private val retentionMaintenance = CacheRetentionMaintenance(clock)

    override fun onCreate(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE encrypted_content (
                device_hash BLOB NOT NULL,
                namespace TEXT NOT NULL,
                item_hash BLOB NOT NULL,
                ciphertext BLOB NOT NULL,
                created_at_ms INTEGER NOT NULL,
                expires_at_ms INTEGER NOT NULL,
                PRIMARY KEY(device_hash, namespace, item_hash)
            )
            """.trimIndent(),
        )
        database.execSQL("CREATE INDEX encrypted_content_expiry ON encrypted_content(expires_at_ms)")
    }

    override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    override fun onOpen(database: SQLiteDatabase) {
        super.onOpen(database)
        retentionMaintenance.prune(SQLiteCacheRetentionDatabase(database))
    }

    fun put(
        deviceId: String,
        namespace: String,
        itemId: String,
        payload: ByteArray,
        nowMillis: Long = clock(),
        retentionMillis: Long = RETENTION_MILLIS,
    ) {
        require(namespace in ALLOWED_NAMESPACES) { "unsupported cache namespace" }
        require(retentionMillis in 1..RETENTION_MILLIS) { "invalid retention" }
        val aad = authenticatedData(deviceId, namespace, itemId)
        val encrypted = encrypt(payload, aad)
        val database = writableDatabase
        retentionMaintenance.pruneAndWrite(SQLiteCacheRetentionDatabase(database), nowMillis) {
            database.execSQL(
                """
                INSERT OR REPLACE INTO encrypted_content
                (device_hash, namespace, item_hash, ciphertext, created_at_ms, expires_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf(hash(deviceId), namespace, hash(itemId), encrypted, nowMillis, nowMillis + retentionMillis),
            )
        }
    }

    fun get(
        deviceId: String,
        namespace: String,
        itemId: String,
        nowMillis: Long = clock(),
    ): CachedContent? {
        val cursor = readableDatabase.rawQuery(
            """
            SELECT ciphertext, created_at_ms, expires_at_ms
            FROM encrypted_content
            WHERE hex(device_hash) = ? AND namespace = ? AND hex(item_hash) = ? AND expires_at_ms > ?
            """.trimIndent(),
            arrayOf(hashHex(deviceId), namespace, hashHex(itemId), nowMillis.toString()),
        )
        cursor.use {
            if (!it.moveToFirst()) return null
            return CachedContent(
                payload = decrypt(it.getBlob(0), authenticatedData(deviceId, namespace, itemId)),
                createdAtMillis = it.getLong(1),
                expiresAtMillis = it.getLong(2),
            )
        }
    }

    fun prune(nowMillis: Long = clock()): Int {
        val database = writableDatabase
        return retentionMaintenance.prune(SQLiteCacheRetentionDatabase(database), nowMillis)
    }

    fun revokeDevice(deviceId: String): Int =
        writableDatabase.delete("encrypted_content", "hex(device_hash) = ?", arrayOf(hashHex(deviceId)))

    fun revokeAll() {
        writableDatabase.delete("encrypted_content", null, null)
        keyStore.deleteEntry(KEY_ALIAS)
    }

    private fun encrypt(plaintext: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
        cipher.updateAAD(aad)
        return cipher.iv + cipher.doFinal(plaintext)
    }

    private fun decrypt(combined: ByteArray, aad: ByteArray): ByteArray {
        require(combined.size >= IV_LENGTH_BYTES + 16) { "invalid encrypted payload" }
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(
            Cipher.DECRYPT_MODE,
            encryptionKey(),
            GCMParameterSpec(128, combined.copyOfRange(0, IV_LENGTH_BYTES)),
        )
        cipher.updateAAD(aad)
        return cipher.doFinal(combined.copyOfRange(IV_LENGTH_BYTES, combined.size))
    }

    private fun encryptionKey(): SecretKey {
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
            generateKey()
        }
    }

    private fun authenticatedData(deviceId: String, namespace: String, itemId: String): ByteArray =
        "galaxybridge-cache-v1\u0000$deviceId\u0000$namespace\u0000$itemId".toByteArray(Charsets.UTF_8)

    private fun hash(value: String): ByteArray = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))

    private fun hashHex(value: String): String = hash(value).joinToString("") { "%02X".format(it) }

    companion object {
        const val NAMESPACE_NOTIFICATIONS = "notifications"
        const val NAMESPACE_SMS = "sms"
        const val NAMESPACE_CLIPBOARD = "clipboard"
        const val RETENTION_MILLIS = 30L * 24 * 60 * 60 * 1_000
        private val ALLOWED_NAMESPACES = setOf(NAMESPACE_NOTIFICATIONS, NAMESPACE_SMS, NAMESPACE_CLIPBOARD)
        private const val DATABASE_NAME = "galaxybridge-content.db"
        private const val DATABASE_VERSION = 1
        private const val KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "com.xopmc.galaxybridge.cache.aes256"
        private const val CIPHER = "AES/GCM/NoPadding"
        private const val IV_LENGTH_BYTES = 12
    }
}

private class SQLiteCacheRetentionDatabase(
    private val database: SQLiteDatabase,
) : CacheRetentionDatabase {
    override fun beginTransaction() = database.beginTransaction()

    override fun deleteExpired(nowMillis: Long): Int =
        database.delete("encrypted_content", "expires_at_ms <= ?", arrayOf(nowMillis.toString()))

    override fun setTransactionSuccessful() = database.setTransactionSuccessful()

    override fun endTransaction() = database.endTransaction()
}
