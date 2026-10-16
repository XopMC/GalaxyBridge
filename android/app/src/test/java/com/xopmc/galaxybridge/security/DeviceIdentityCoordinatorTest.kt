package com.xopmc.galaxybridge.security

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DeviceIdentityCoordinatorTest {
    @Test fun independentKeyStoresCannotGenerateDifferentFirstIdentities() {
        assertSingleCreation { read, generate, commit ->
            DeviceIdentityCoordinator.withIdentity {
                read() ?: generate().also { check(commit(it)) }
            }
        }
    }

    @Test fun pairingAndServerDeviceIdsShareOneCommittedCreation() {
        assertSingleCreation { read, generate, commit ->
            DeviceIdentityCoordinator.getOrCreateDeviceId(read, generate, commit)
        }
    }

    @Test fun existingDeviceIdIsPreservedWithoutGeneratingOrWriting() {
        val stored = DeviceIdentityCoordinator.getOrCreateDeviceId(
            read = { "existing-paired-device" },
            generate = { error("Existing identities must not rotate") },
            commit = { error("Existing identities must not be rewritten") },
        )
        assertEquals("existing-paired-device", stored)
    }

    @Test fun failedPersistenceIsNeverReturnedOrCached() {
        var stored: String? = null
        try {
            DeviceIdentityCoordinator.getOrCreateDeviceId({ stored }, { "not-durable" }, { false })
            fail("An uncommitted device ID must not escape")
        } catch (_: IllegalStateException) {
            assertNull(stored)
        }
        val value = DeviceIdentityCoordinator.getOrCreateDeviceId(
            { stored }, { "durable" }, { stored = it; true },
        )
        assertEquals("durable", value)
        assertEquals(value, stored)
    }

    @Test fun revocationWaitsForSigningAndNextAccessCanCreateFreshIdentity() {
        val identity = AtomicReference<String?>("original-key")
        val signing = CountDownLatch(1)
        val finishSigning = CountDownLatch(1)
        val revokeAttempting = CountDownLatch(1)
        val revoking = CountDownLatch(1)
        val workers = Executors.newFixedThreadPool(2)
        try {
            val signed = workers.submit<Pair<String?, String?>> {
                DeviceIdentityCoordinator.withIdentity {
                    val before = identity.get()
                    signing.countDown()
                    check(finishSigning.await(3, TimeUnit.SECONDS))
                    before to identity.get()
                }
            }
            assertTrue(signing.await(3, TimeUnit.SECONDS))
            val revoked = workers.submit {
                revokeAttempting.countDown()
                DeviceIdentityCoordinator.withIdentity {
                    identity.set(null)
                    revoking.countDown()
                }
            }
            assertTrue(revokeAttempting.await(3, TimeUnit.SECONDS))
            val overlapped = revoking.await(150, TimeUnit.MILLISECONDS)
            finishSigning.countDown()
            assertEquals("original-key" to "original-key", signed.get(3, TimeUnit.SECONDS))
            revoked.get(3, TimeUnit.SECONDS)
            assertFalse("Revocation must not invalidate a key while signing", overlapped)
            assertNull(identity.get())
            val next = DeviceIdentityCoordinator.withIdentity {
                identity.get() ?: "fresh-key".also(identity::set)
            }
            assertEquals("fresh-key", next)
        } finally {
            finishSigning.countDown()
            workers.shutdownNow()
        }
    }

    /** Force the old check/generate race: first read holds its null result while
     * a second independent caller attempts the same persisted alias/key. */
    private fun assertSingleCreation(
        access: (() -> String?, () -> String, (String) -> Boolean) -> String,
    ) {
        val stored = AtomicReference<String?>()
        val reads = AtomicInteger()
        val creations = AtomicInteger()
        val firstRead = CountDownLatch(1)
        val releaseFirstRead = CountDownLatch(1)
        val secondRead = CountDownLatch(1)
        val secondAttempting = CountDownLatch(1)
        val workers = Executors.newFixedThreadPool(2)
        val read = {
            val observed = stored.get()
            if (reads.incrementAndGet() == 1) {
                firstRead.countDown()
                check(releaseFirstRead.await(3, TimeUnit.SECONDS))
            } else {
                secondRead.countDown()
            }
            observed
        }
        val generate = { "identity-${creations.incrementAndGet()}" }
        val commit: (String) -> Boolean = { stored.set(it); true }
        try {
            val first = workers.submit<String> { access(read, generate, commit) }
            assertTrue(firstRead.await(3, TimeUnit.SECONDS))
            val second = workers.submit<String> {
                secondAttempting.countDown()
                access(read, generate, commit)
            }
            assertTrue(secondAttempting.await(3, TimeUnit.SECONDS))
            val overlapped = secondRead.await(150, TimeUnit.MILLISECONDS)
            releaseFirstRead.countDown()
            val identity = first.get(3, TimeUnit.SECONDS)
            assertEquals(identity, second.get(3, TimeUnit.SECONDS))
            assertEquals(identity, stored.get())
            assertEquals(1, creations.get())
            assertFalse("Another store entered read/generate before persistence", overlapped)
        } finally {
            releaseFirstRead.countDown()
            workers.shutdownNow()
        }
    }
}
