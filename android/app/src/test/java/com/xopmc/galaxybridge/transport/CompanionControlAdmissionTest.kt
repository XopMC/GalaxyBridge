package com.xopmc.galaxybridge.transport

import org.junit.Assert.*
import org.junit.Test

class CompanionControlAdmissionTest {
    @Test fun reconnectsRetainBudgetUntilOldOperationAndRetirementActuallySettle() {
        val admission = CompanionControlAdmission(maxPerHost = 2, maxTotal = 3)
        val draining = requireNotNull(admission.acquire("mac1"))
        val replacement = requireNotNull(admission.acquire("mac1"))
        assertNull(admission.acquire("mac1"))
        val another = requireNotNull(admission.acquire("mac2"))
        assertNull(admission.acquire("mac3"))
        draining.close()
        val next = requireNotNull(admission.acquire("mac1"))
        // A stale/double release cannot free the replacement's permit.
        draining.close()
        assertNull(admission.acquire("mac1")); assertNull(admission.acquire("mac3"))
        replacement.close(); next.close(); another.close()
        assertNotNull(admission.acquire("mac3"))
    }
}
