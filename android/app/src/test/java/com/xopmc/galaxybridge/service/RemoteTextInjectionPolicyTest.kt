package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteTextInjectionPolicyTest {
    @Test
    fun `accessibility is authoritative when an editable node accepts text`() {
        val calls = mutableListOf<String>()

        val delivered = RemoteTextInjectionPolicy.deliver(
            accessibility = { calls += "accessibility"; true },
            imeFallback = { calls += "ime"; true },
        )

        assertTrue(delivered)
        assertEquals(listOf("accessibility"), calls)
    }

    @Test
    fun `ime is only a fallback when accessibility cannot edit`() {
        val calls = mutableListOf<String>()

        val delivered = RemoteTextInjectionPolicy.deliver(
            accessibility = { calls += "accessibility"; false },
            imeFallback = { calls += "ime"; true },
        )

        assertTrue(delivered)
        assertEquals(listOf("accessibility", "ime"), calls)
    }
}
