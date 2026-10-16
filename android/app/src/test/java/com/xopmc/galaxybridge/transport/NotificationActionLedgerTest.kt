package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.service.NotificationActionExecution
import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationActionLedgerTest {
    private val id = "69830b65-6352-4b3a-8a21-70bcda45787e"

    @Test fun duplicateRequestReturnsOriginalAcceptanceWithoutSendingTwice() {
        var sends = 0
        val ledger = NotificationActionLedger()
        repeat(3) { assertEquals(NotificationActionExecution(true), ledger.execute(id, "digest") { sends++; NotificationActionExecution(true) }) }
        assertEquals(1, sends)
        assertEquals("request_id_reused", ledger.execute(id, "changed") { error("must not execute") }.errorCode)
    }

    @Test fun rejectionAndCanceledActionAreStableReceiptsToo() {
        val ledger = NotificationActionLedger()
        assertEquals("pending_intent_canceled", ledger.execute(id, "digest") { NotificationActionExecution(false, "pending_intent_canceled") }.errorCode)
        assertEquals("pending_intent_canceled", ledger.execute(id, "digest") { error("must not execute") }.errorCode)
    }

    @Test fun invalidRequestsNeverExecuteAndRollingWindowNeverLimitsFreshActions() {
        val ledger = NotificationActionLedger(capacity = 2)
        assertEquals("invalid_request_id", ledger.execute("invalid", "digest") { error("must not execute") }.errorCode)
        var calls = 0
        val ids = (0..10).map { java.util.UUID(0, it.toLong()).toString() }
        ids.forEach { requestId ->
            assertEquals(NotificationActionExecution(true), ledger.execute(requestId, "digest") { calls++; NotificationActionExecution(true) })
        }
        assertEquals(11, calls)
        assertEquals(NotificationActionExecution(true), ledger.execute(ids.last(), "digest") { error("recent duplicate") })
        // An evicted UUID is outside our guarantee. The Mac never automatically resends it.
        ledger.execute(ids.first(), "digest") { calls++; NotificationActionExecution(true) }
        assertEquals(12, calls)
    }

    @Test fun unexpectedPlatformFailureBecomesErrorAndNeverReexecutes() {
        val ledger = NotificationActionLedger()
        assertEquals("action_rejected", ledger.execute(id, "digest") { throw IllegalStateException() }.errorCode)
        assertEquals("action_rejected", ledger.execute(id, "digest") { error("must not execute") }.errorCode)
    }
}
