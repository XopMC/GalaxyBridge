package com.xopmc.galaxybridge.service

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NotificationAppIconEncoderTest {
    @Test
    fun acceptsBoundedPngAndRejectsMalformedOrOversizedPayloads() {
        val png = byteArrayOf(
            0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        )
        assertArrayEquals(png, NotificationAppIconEncoder.safePngPayload(png))
        assertNull(NotificationAppIconEncoder.safePngPayload("not-png".toByteArray()))
        assertNull(
            NotificationAppIconEncoder.safePngPayload(
                png + ByteArray(NotificationAppIconEncoder.MAX_PNG_BYTES),
            ),
        )
    }
}
