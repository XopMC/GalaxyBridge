package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.service.NotificationActionExecution
import java.util.UUID

/** Last 512 receipts on one authenticated control socket, in access order.
 * Deduplication covers only this bounded recent window. Clients never replay/retry automatically. */
internal class NotificationActionLedger(private val capacity: Int = 512) {
    init { require(capacity > 0) }
    private data class Receipt(val fingerprint: String, val outcome: NotificationActionExecution)
    private val receipts = linkedMapOf<String, Receipt>()

    fun execute(requestId: String, fingerprint: String, action: () -> NotificationActionExecution): NotificationActionExecution {
        if (!runCatching { UUID.fromString(requestId).toString() == requestId }.getOrDefault(false)) {
            return NotificationActionExecution(false, "invalid_request_id")
        }
        receipts[requestId]?.let {
            receipts.remove(requestId)
            receipts[requestId] = it
            return if (it.fingerprint == fingerprint) it.outcome else NotificationActionExecution(false, "request_id_reused")
        }
        val outcome = try { action() } catch (_: Exception) { NotificationActionExecution(false, "action_rejected") }
        if (receipts.size >= capacity) receipts.remove(receipts.keys.first())
        receipts[requestId] = Receipt(fingerprint, outcome)
        return outcome
    }
}
