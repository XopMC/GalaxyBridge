package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteTextBatcherTest {
    @Test
    fun `rapid text packets are delivered as one ordered edit`() {
        val delivered = mutableListOf<String>()
        val batcher = RemoteTextBatcher(delivered::add)

        val first = batcher.enqueue("GB_LAN_К")
        val second = batcher.enqueue("ЛАВА_42")
        batcher.flush(first)
        batcher.flush(second)

        assertEquals(listOf("GB_LAN_КЛАВА_42"), delivered)
    }

    @Test
    fun `a non-text command can synchronously drain pending text`() {
        val delivered = mutableListOf<String>()
        val batcher = RemoteTextBatcher(delivered::add)

        batcher.enqueue("before-key")
        batcher.flushNow()

        assertEquals(listOf("before-key"), delivered)
    }
}
