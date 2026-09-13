package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteTextPayloadTest {
    @Test
    fun `round trips bounded Unicode without exposing raw text in shell arguments`() {
        val text = "Привет 🌉 Galaxy"
        val encoded = RemoteTextPayload.encode(text)

        assertEquals(text, RemoteTextPayload.decode(encoded))
        assertNull(RemoteTextPayload.decode("not-base64"))
        assertNull(RemoteTextPayload.decode(RemoteTextPayload.encode("x".repeat(4_097))))
    }
}
