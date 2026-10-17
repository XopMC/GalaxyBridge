package com.xopmc.galaxybridge.transport.shell

import org.junit.Assert.*
import org.junit.Test

class ShellRuntimeIdentityTest {
    @Test fun exactBytesAndLegacyAbsence() {
        assertArrayEquals(ByteArray(0), ShellRuntimeIdentity.decode(""))
        assertArrayEquals(ByteArray(32) { it.toByte() }, ShellRuntimeIdentity.decode(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
    }
    @Test fun statusIdentityEncodingIsBoundedAndCanonical() {
        assertEquals("", ShellRuntimeIdentity.encode(ByteArray(0)))
        val bytes = ByteArray(32) { it.toByte() }
        assertEquals("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", ShellRuntimeIdentity.encode(bytes))
        assertArrayEquals(bytes, ShellRuntimeIdentity.decode(ShellRuntimeIdentity.encode(bytes)))
        for (size in listOf(1, 31, 33)) {
            try { ShellRuntimeIdentity.encode(ByteArray(size)); fail("Malformed runtime digest encoded") }
            catch (_: IllegalArgumentException) {}
        }
    }
    @Test fun malformedIdentityFailsClosed() {
        for (invalid in listOf("0".repeat(63), "0".repeat(65), "G".repeat(64), "A".repeat(64), "０".repeat(64), " "+"0".repeat(64))) {
            try { ShellRuntimeIdentity.decode(invalid); fail("Malformed runtime identity admitted") }
            catch (_: IllegalArgumentException) {}
        }
    }
}
