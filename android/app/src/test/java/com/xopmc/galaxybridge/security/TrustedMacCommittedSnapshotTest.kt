package com.xopmc.galaxybridge.security

import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class TrustedMacCommittedSnapshotTest {
    private class Storage : TrustedMacStorage {
        var encoded: String? = null
        var reads = 0
        var writes = 0
        var succeeds = true
        var notifications = 0
        var observe: (TrustedMacRoster) -> Unit = {}
        var uncertainAfterWrite = false
        var legacy: TrustedMac? = null
        override fun read(): String? { reads++; return encoded }
        override fun readLegacy(): TrustedMac? = legacy
        override fun write(encoded: String): Boolean {
            writes++
            if (succeeds) this.encoded = encoded
            if (uncertainAfterWrite) throw TrustedMacStorageUncertain(java.io.IOException("publication unknown"))
            return succeeds
        }
        override fun committed(snapshot: TrustedMacRoster) { notifications++; observe(snapshot) }
    }

    private fun mac() = TrustedMac(
        "00000000-0000-4000-8000-000000000001",
        Base64.getEncoder().encodeToString(ByteArray(65) { if (it == 0) 4 else 1 }),
        "Mac", 1000,
    )

    @Test fun highFrequencyAuthorityReadsUseOneCommittedSnapshotWithoutDiskIO() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        val host = mac()
        repository.snapshot()
        assertTrue(repository.add(host))
        repeat(1000) { assertEquals(host.hostID, repository.snapshot().activeHostID) }
        assertEquals("Each input event must not read and decode the trust file", 1, storage.reads)
    }

    @Test fun failedWriteCannotPublishOptimisticTrust() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        repository.add(mac())
        val previous = repository.snapshot()
        storage.succeeds = false
        assertFalse(repository.forget(mac().hostID))
        assertEquals(previous, repository.snapshot())
        assertEquals(1, storage.notifications)
    }

    @Test fun synchronousObserverSeesTheNewDurableSnapshotWithoutRereadingDisk() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        storage.observe = { announced ->
            assertEquals(announced, TrustedMacRoster.decode(requireNotNull(storage.encoded)))
            assertSame(announced, repository.snapshot())
        }
        assertTrue(repository.add(mac()))
        assertTrue(repository.forget(mac().hostID))
        assertEquals(2, storage.notifications)
        assertEquals(1, storage.reads)
    }

    @Test fun independentComponentsInOneDataDirectoryShareExactlyOneAuthority() {
        val registry = TrustedMacRepositoryRegistry()
        val storage = Storage()
        val pairing = registry.repository("app-data") { storage }
        val control = registry.repository("app-data") { error("must reuse the application repository") }
        val separateProfile = registry.repository("isolated-test-profile") { Storage() }
        assertSame(pairing, control)
        assertTrue(pairing.add(mac()))
        assertNotNull(control.snapshot().find(mac().hostID))
        assertTrue(control.forget(mac().hostID))
        assertNull(pairing.snapshot().find(mac().hostID))
        assertTrue(separateProfile.snapshot().macs.isEmpty())
        assertEquals(1, storage.reads)
    }

    @Test fun ambiguousPublicationFencesCachedAuthorityUntilExplicitRetirementReconciliation() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        repository.add(mac())
        storage.uncertainAfterWrite = true
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.forget(mac().hostID) }
        val writes = storage.writes
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.snapshot() }
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.add(mac()) }
        assertEquals(writes, storage.writes)
        storage.uncertainAfterWrite = false
        assertTrue(repository.reconcileAfterRetirement().macs.isEmpty())
        assertTrue(repository.snapshot().macs.isEmpty())
    }

    @Test fun malformedReconciliationCannotRestoreAdmission() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        repository.add(mac())
        storage.uncertainAfterWrite = true
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.forget(mac().hostID) }
        storage.encoded = "broken"
        assertThrows(IllegalStateException::class.java) { repository.reconcileAfterRetirement() }
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.snapshot() }
    }

    @Test fun failedRecoveryDurabilityBarrierKeepsAuthorityFenced() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        repository.add(mac())
        storage.uncertainAfterWrite = true
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.forget(mac().hostID) }
        storage.uncertainAfterWrite = false
        storage.succeeds = false
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.reconcileAfterRetirement() }
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.snapshot() }
        storage.succeeds = true
        assertTrue(repository.reconcileAfterRetirement().macs.isEmpty())
    }

    @Test fun legacyRecoveryPersistsCanonicalTrustBeforeLegacyCleanup() {
        val original = mac()
        val storage = Storage().apply { legacy = original; uncertainAfterWrite = true }
        val repository = TrustedMacRepository(storage)
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.snapshot() }
        storage.encoded = null
        storage.uncertainAfterWrite = false
        storage.observe = { storage.legacy = null }
        assertEquals(original, repository.reconcileAfterRetirement().find(original.hostID))
        assertNotNull(storage.encoded)
        assertNull(storage.legacy)
        assertEquals(original, TrustedMacRepository(storage).snapshot().find(original.hostID))
    }

    @Test fun realPublicationHelperCannotClearAnUncertainRecoveryAfterStartWriteFails() {
        var stored: String? = null
        var mode = "success"
        val repository = TrustedMacRepository(object : TrustedMacStorage {
            override fun read() = stored
            override fun readLegacy(): TrustedMac? = null
            override fun write(encoded: String) = TrustedMacPublication.commit(encoded, { stored }) {
                if (mode == "prewrite-failure") throw java.io.IOException("startWrite failed")
                stored = it
                if (mode == "uncertain") throw TrustedMacStorageUncertain(java.io.IOException("directory sync failed"))
            }
        })
        repository.add(mac())
        mode = "uncertain"
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.forget(mac().hostID) }
        mode = "prewrite-failure"
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.reconcileAfterRetirement() }
        assertThrows(TrustedMacStorageUncertain::class.java) { repository.snapshot() }
        mode = "success"
        assertTrue(repository.reconcileAfterRetirement().macs.isEmpty())
    }
}
