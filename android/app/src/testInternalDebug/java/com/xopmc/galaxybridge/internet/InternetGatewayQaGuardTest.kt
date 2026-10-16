package com.xopmc.galaxybridge.internet

import org.junit.Assert.*
import org.junit.Test

class InternetGatewayQaGuardTest {
    private val id = "12345678-1234-4234-8234-123456789abc"
    private val token = "ab".repeat(32)
    @Test fun rejectsMalformedOrUnscopedRequests() {
        assertFalse(InternetGatewayQaGuard.valid("1-1-1-1-1", token, "prepare"))
        assertFalse(InternetGatewayQaGuard.valid(id, "aa", "prepare"))
        assertFalse(InternetGatewayQaGuard.valid(id, token.uppercase(), "prepare"))
        assertFalse(InternetGatewayQaGuard.valid(id, token, "shell"))
        assertTrue(InternetGatewayQaGuard.valid(id, token, "cleanup"))
    }
    @Test fun authenticationAndExpiryAreExactAndCannotRenew() {
        val guard = InternetGatewayQaGuard(id, token, 100)
        assertTrue(guard.authorizes(id, token, 30_099))
        assertFalse(guard.authorizes(id, token, 30_100))
        assertFalse(guard.authorizes(id, "cd".repeat(32), 101))
        assertFalse(guard.authorizes("22345678-1234-4234-8234-123456789abc", token, 101))
        assertTrue(guard.matches(id, token)) // cleanup remains authorized after expiry
        assertEquals(30_100L, guard.deadline)
    }
}
