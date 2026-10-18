package com.xopmc.galaxybridge.security

/** Neither the preceding nor proposed authority may be served until reconciled. */
internal class TrustedMacStorageUncertain(cause: Throwable? = null) :
    IllegalStateException("trusted_mac_storage_requires_reconciliation", cause)

/** AtomicFile can log a rename error instead of throwing; verify publication explicitly. */
internal object TrustedMacPublication {
    fun commit(encoded: String, read: () -> String?, replace: (String) -> Unit): Boolean {
        val previous = try { read() } catch (error: Exception) { throw TrustedMacStorageUncertain(error) }
        var replacementFailure: Exception? = null
        try {
            replace(encoded)
        } catch (uncertain: TrustedMacStorageUncertain) {
            // A failed durability barrier remains uncertain even if new bytes are visible.
            throw uncertain
        } catch (error: Exception) {
            replacementFailure = error
        }
        val observed = try { read() } catch (error: Exception) { throw TrustedMacStorageUncertain(error) }
        if (replacementFailure != null) {
            if (observed == previous) return false
            throw TrustedMacStorageUncertain(replacementFailure)
        }
        return when (observed) {
            encoded -> true
            previous -> false
            else -> throw TrustedMacStorageUncertain()
        }
    }
}
