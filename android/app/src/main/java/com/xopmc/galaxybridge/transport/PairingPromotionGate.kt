package com.xopmc.galaxybridge.transport

import java.security.MessageDigest

/** Exempts only preference callbacks inside this thread's exact authorized commit. */
internal class PairingPromotionGate {
    private data class Identity(val host: String,val key: ByteArray,val retain: () -> Unit)
    private val expected = ThreadLocal<Identity?>()
    fun matches(host: String?, key: ByteArray?): Boolean = expected.get()?.let {
        host == it.host && key != null && MessageDigest.isEqual(it.key,key)
    } == true
    fun preserve(host: String?,key: ByteArray?): Boolean {
        if (!matches(host,key)) return false
        expected.get()!!.retain(); return true
    }
    fun <T> during(host: String,key: ByteArray,retain: () -> Unit = {},operation: () -> T): T {
        check(expected.get() == null)
        expected.set(Identity(host,key.clone(),retain))
        try { return operation() } finally { expected.remove() }
    }
}

/** Actual preference-listener boundary shared with the foreground service. */
internal class PairingIdentityChangeListener(private val revokeResources: () -> Unit,private val identityChanged: () -> Unit) {
    fun changed(key: String?) {
        if (key == "paired_mac_key" || key == "paired_host_id") {
            revokeResources()
            identityChanged()
        }
    }
}
