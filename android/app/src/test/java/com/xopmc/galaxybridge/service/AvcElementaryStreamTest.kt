package com.xopmc.galaxybridge.service

import org.junit.Assert.assertArrayEquals
import org.junit.Test

class AvcElementaryStreamTest {
    @Test
    fun convertsLengthPrefixedAccessUnitToAnnexB() {
        val lengthPrefixed = byteArrayOf(
            0, 0, 0, 2, 0x67, 0x11,
            0, 0, 0, 2, 0x68, 0x22,
        )
        assertArrayEquals(
            byteArrayOf(
                0, 0, 0, 1, 0x67, 0x11,
                0, 0, 0, 1, 0x68, 0x22,
            ),
            AvcElementaryStream.toAnnexB(lengthPrefixed),
        )
    }

    @Test
    fun keepsAnnexBPayloadUnchanged() {
        val annexB = byteArrayOf(0, 0, 0, 1, 0x65, 0x44)
        assertArrayEquals(annexB, AvcElementaryStream.toAnnexB(annexB))
    }
}
