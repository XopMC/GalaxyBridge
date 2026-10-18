package com.xopmc.galaxybridge.security

import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class TrustedMacRosterTest {
    private fun mac(number: Int, key: Int = number) = TrustedMac(
        "00000000-0000-4000-8000-%012d".format(number),
        Base64.getEncoder().encodeToString(ByteArray(65) { if (it == 0) 4 else key.toByte() }),
        "Mac $number", 1000L + number,
        trustOccurrenceID = "10000000-0000-4000-8000-%012d".format(number),
    )
    private class Storage(var encoded: String? = null, val legacy: TrustedMac? = null) : TrustedMacStorage {
        var succeeds = true
        var writes = 0
        override fun read() = encoded
        override fun readLegacy() = legacy
        override fun write(encoded: String): Boolean {
            writes++
            if (succeeds) this.encoded = encoded
            return succeeds
        }
    }

    @Test fun legacyMigrationPreservesKeyTimestampAndTransferIdentity() {
        val original = mac(1)
        val storage = Storage(legacy = original)
        val repository = TrustedMacRepository(storage)
        val snapshot = repository.snapshot()
        assertEquals(original, snapshot.find(original.hostID))
        assertEquals(original.hostID, snapshot.activeHostID)
        assertEquals(0, snapshot.epoch)
        assertNotNull(storage.encoded)
        assertEquals(snapshot, TrustedMacRoster.decode(storage.encoded!!))
        repository.snapshot()
        assertEquals(1, storage.writes)
    }

    @Test fun failedMigrationCannotDiscardLegacyTrustOrPretendMutationSucceeded() {
        val storage = Storage(legacy = mac(1)).apply { succeeds = false }
        val repository = TrustedMacRepository(storage)
        assertEquals(mac(1), repository.snapshot().find(mac(1).hostID))
        assertFalse(repository.add(mac(2)))
        assertNull(storage.encoded)
        assertNull(repository.snapshot().find(mac(2).hostID))
    }

    @Test fun addingMacDoesNotStealActiveOwnershipOrReplaceOriginalPairingTime() {
        val repository = TrustedMacRepository(Storage())
        assertTrue(repository.add(mac(1)))
        assertTrue(repository.add(mac(2)))
        assertEquals(mac(1).hostID, repository.snapshot().activeHostID)
        assertTrue(repository.add(mac(1).copy(displayName = "Renamed", pairedAtMillis = 9000)))
        assertEquals(1001L, repository.snapshot().find(mac(1).hostID)!!.pairedAtMillis)
        assertEquals("Renamed", repository.snapshot().find(mac(1).hostID)!!.displayName)
    }

    @Test fun sameHostCannotSilentlyReplaceItsKey() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        assertTrue(repository.add(mac(1)))
        val before = storage.encoded
        assertThrows(IllegalArgumentException::class.java) { repository.add(mac(1, 2)) }
        assertEquals(before, storage.encoded)
    }

    @Test fun selectionIsDurableEpochFencedAndFailureLeavesPreviousOwner() {
        val storage = Storage()
        val repository = TrustedMacRepository(storage)
        repository.add(mac(1)); repository.add(mac(2))
        assertFalse(repository.select(mac(2).hostID, expectedEpoch = 7))
        storage.succeeds = false
        assertFalse(repository.select(mac(2).hostID, expectedEpoch = 0))
        assertEquals(mac(1).hostID, repository.snapshot().activeHostID)
        storage.succeeds = true
        assertTrue(repository.select(mac(2).hostID, expectedEpoch = 0))
        assertEquals(1, repository.snapshot().epoch)
        assertFalse(repository.select(mac(1).hostID, expectedEpoch = 0))
        assertTrue(repository.select(mac(2).hostID, expectedEpoch = 1))
        assertEquals(1, repository.snapshot().epoch)
    }

    @Test fun removalDoesNotGrantRemainingMacImplicitControl() {
        val repository = TrustedMacRepository(Storage())
        repository.add(mac(1)); repository.add(mac(2))
        assertTrue(repository.forget(mac(1).hostID))
        assertNull(repository.snapshot().activeHostID)
        assertEquals(1, repository.snapshot().epoch)
        assertNotNull(repository.snapshot().find(mac(2).hostID))
        assertTrue(repository.select(mac(2).hostID, expectedEpoch = 1))
    }

    @Test fun rosterAndCodecAreBoundedAndRejectAmbiguousOrMalformedRecords() {
        val repository = TrustedMacRepository(Storage())
        (1..16).forEach { assertTrue(repository.add(mac(it))) }
        assertThrows(IllegalArgumentException::class.java) { repository.add(mac(17)) }
        assertEquals(repository.snapshot(), TrustedMacRoster.decode(repository.snapshot().encode()))
        for (bad in listOf("", "%%%", "A".repeat(40000),
            repository.snapshot().encode() + "AAAA")) {
            assertThrows(IllegalArgumentException::class.java) { TrustedMacRoster.decode(bad) }
        }
        assertThrows(IllegalArgumentException::class.java) { TrustedMacRoster(listOf(mac(1), mac(1)), mac(1).hostID, 0) }
        assertThrows(IllegalArgumentException::class.java) { TrustedMacRoster(listOf(mac(1)), mac(2).hostID, 0) }
        assertThrows(IllegalArgumentException::class.java) { repository.add(mac(2).copy(publicKeyBase64 = "AQ==")) }
    }

    @Test fun corruptDurableSnapshotFailsClosedWithoutOverwritingOrFallingBackToLegacy() {
        val storage = Storage(encoded = "broken", legacy = mac(1))
        val repository = TrustedMacRepository(storage)
        assertThrows(IllegalStateException::class.java) { repository.snapshot() }
        assertThrows(IllegalStateException::class.java) { repository.add(mac(2)) }
        assertEquals("broken", storage.encoded)
        assertEquals(0, storage.writes)
    }

    @Test fun namesArePlainBoundedPresentationData() {
        val repository = TrustedMacRepository(Storage())
        repository.add(mac(1).copy(displayName = "  My\nMac\u202E" + "x".repeat(200)))
        val name = repository.snapshot().macs.single().displayName
        assertTrue(name.length <= 80)
        assertFalse(name.contains('\n'))
        assertFalse(name.contains('\u202E'))
        repository.add(mac(2).copy(displayName = "x".repeat(80) + "\n".repeat(30)))
        assertEquals(80, repository.snapshot().find(mac(2).hostID)!!.displayName.length)
    }

    @Test fun callerCannotMutateAValidatedRosterAfterConstruction() {
        val input = mutableListOf(mac(1))
        val roster = TrustedMacRoster(input, mac(1).hostID, 0)
        input.clear()
        assertEquals(1, roster.macs.size)
        assertThrows(UnsupportedOperationException::class.java) { (roster.macs as MutableList).clear() }
    }

    @Test fun inactiveForgetAndRePairInvalidateOldTrustEvenWithTheSameKeyAndTimestamp() {
        val repository = TrustedMacRepository(Storage())
        val old = mac(2)
        repository.add(mac(1)); repository.add(old)
        val epoch = repository.snapshot().epoch
        repository.forget(old.hostID)
        val next = old.copy(trustOccurrenceID = "20000000-0000-4000-8000-000000000002")
        repository.add(next)
        val restored = repository.snapshot().find(old.hostID)!!
        assertEquals(epoch, repository.snapshot().epoch)
        assertEquals(old.pairedAtMillis, restored.pairedAtMillis)
        assertFalse(old.sameTrustAs(restored))
        assertEquals(next.publicKeyBase64, restored.publicKeyBase64)
        assertEquals(restored, TrustedMacRoster.decode(repository.snapshot().encode()).find(old.hostID))
    }

    @Test fun renameAndPairingRetryPreserveTheExistingTrustOccurrence() {
        val repository = TrustedMacRepository(Storage())
        repository.add(mac(1))
        val original = repository.snapshot().find(mac(1).hostID)!!
        repository.add(original.copy(displayName = "New name", pairedAtMillis = 9999,
            trustOccurrenceID = "20000000-0000-4000-8000-000000000001"))
        assertTrue(original.sameTrustAs(repository.snapshot().find(original.hostID)))
        assertFalse(original.sameTrustAs(null))
        assertFalse(original.sameTrustAs(original.copy(pairedAtMillis = 9999)))
    }

    @Test fun newlyConstructedTrustHasItsOwnOccurrenceEvenAtTheSameClockInstant() {
        val fixture = mac(1)
        val first = TrustedMac(fixture.hostID, fixture.publicKeyBase64, fixture.displayName, fixture.pairedAtMillis)
        val second = TrustedMac(fixture.hostID, fixture.publicKeyBase64, fixture.displayName, fixture.pairedAtMillis)
        assertNotEquals(first.trustOccurrenceID, second.trustOccurrenceID)
    }

    @Test fun versionOneSnapshotMigratesToAStableOccurrenceWithoutChangingTransferIdentity() {
        val legacy = "R0JNMQAAAAAAAAAAACQwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDEAAAABACQwMDAwMDAwMC0wMDAwLTQwMDAtODAwMC0wMDAwMDAwMDAwMDEAWEJBRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRUJBUUVCQVFFQkFRRT0AA01hYwAAAAAAAAPp"
        val first = TrustedMacRoster.decode(legacy)
        val again = TrustedMacRoster.decode(legacy)
        assertEquals(first.macs.single().trustOccurrenceID, again.macs.single().trustOccurrenceID)
        assertEquals(mac(1).hostID, first.activeHostID)
        assertEquals(mac(1).publicKeyBase64, first.macs.single().publicKeyBase64)
        assertEquals(mac(1).pairedAtMillis, first.macs.single().pairedAtMillis)
        assertNotEquals(legacy, first.encode())
        assertEquals(first, TrustedMacRoster.decode(first.encode()))
    }

    @Test fun reusingAForgottenRecordCannotReviveItsOldAuthority() {
        val repository = TrustedMacRepository(Storage())
        repository.add(mac(1)); repository.add(mac(2))
        val forgotten = repository.snapshot().find(mac(2).hostID)!!
        val epoch = repository.snapshot().epoch
        repository.forget(forgotten.hostID)
        repository.add(forgotten)
        val replacement = repository.snapshot().find(forgotten.hostID)!!
        assertEquals(epoch, repository.snapshot().epoch)
        assertEquals(forgotten.pairedAtMillis, replacement.pairedAtMillis)
        assertFalse(forgotten.sameTrustAs(replacement))
    }
}
