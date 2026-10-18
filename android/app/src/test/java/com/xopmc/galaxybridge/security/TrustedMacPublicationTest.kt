package com.xopmc.galaxybridge.security

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class TrustedMacPublicationTest {
    @Test fun visibleChangesAfterWriterFailureDoNotProveDurability() {
        var stored: String? = "old"
        assertFalse(TrustedMacPublication.commit("new", { stored }) { throw IOException("before replacement") })
        assertEquals("old", stored)
        assertThrows(TrustedMacStorageUncertain::class.java) {
            TrustedMacPublication.commit("new", { stored }) {
                stored = it
                throw IOException("replacement visible but writer did not finish")
            }
        }
        assertEquals("new", stored)
    }

    @Test fun unchangedBytesCannotProveAResealAfterWriterFailure() {
        assertFalse(TrustedMacPublication.commit("same", { "same" }) { throw IOException("startWrite failed") })
    }

    @Test fun silentAtomicRenameFailureCannotBeAcknowledgedAsSuccess() {
        assertFalse(TrustedMacPublication.commit("new", { "old" }) { /* platform logged a rename failure */ })
    }

    @Test fun unreadableOrUnexpectedReadbackRemainsIndeterminate() {
        var reads = 0
        assertThrows(TrustedMacStorageUncertain::class.java) {
            TrustedMacPublication.commit("new", {
                if (++reads == 1) "old" else throw IOException("readback unavailable")
            }) {}
        }
        reads = 0
        assertThrows(TrustedMacStorageUncertain::class.java) {
            TrustedMacPublication.commit("new", { if (++reads == 1) "old" else "unexpected" }) {}
        }
    }

    @Test fun failedDurabilityBarrierCannotBeClearedBySeeingTheNewBytes() {
        var stored = "old"
        assertThrows(TrustedMacStorageUncertain::class.java) {
            TrustedMacPublication.commit("new", { stored }) {
                stored = it
                throw TrustedMacStorageUncertain(IOException("directory sync failed"))
            }
        }
        assertEquals("new", stored)
    }
}
