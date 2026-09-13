package com.xopmc.galaxybridge.service

import com.xopmc.galaxybridge.protocol.v1.ClipboardKind
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class ClipboardOutboundHubTest {
    @Test
    fun reportsDisconnectedAndQueuePressureWithoutSilentSuccess() = runBlocking {
        val hub = ClipboardOutboundHub(capacity = 1)
        val first = payload("first")
        val second = payload("second")

        assertEquals(ClipboardOutboundResult.NO_CONNECTED_MAC, hub.publish(first))

        val subscription = hub.subscribe()
        assertEquals(ClipboardOutboundResult.SENT, hub.publish(first))
        assertEquals(ClipboardOutboundResult.QUEUE_FULL, hub.publish(second))
        assertEquals(first, subscription.events.first())

        subscription.close()
        assertEquals(ClipboardOutboundResult.NO_CONNECTED_MAC, hub.publish(second))
    }

    @Test
    fun oneLiveAcceptingMacIsARealDeliveryEvenIfAStaleParallelChannelIsFull() = runBlocking {
        val hub = ClipboardOutboundHub(capacity = 1)
        val live = hub.subscribe()
        val stale = hub.subscribe()
        val first = payload("first")
        val second = payload("second")

        assertEquals(ClipboardOutboundResult.SENT, hub.publish(first))
        assertEquals(first, live.events.first())
        assertEquals(ClipboardOutboundResult.SENT, hub.publish(second))
        assertEquals(second, live.events.first())

        live.close()
        stale.close()
    }

    private fun payload(value: String) = ClipboardPayload(
        kind = ClipboardKind.CLIPBOARD_KIND_TEXT,
        content = value.encodeToByteArray(),
        changeId = value,
    )
}
