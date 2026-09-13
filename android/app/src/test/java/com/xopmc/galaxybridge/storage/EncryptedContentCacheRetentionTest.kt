package com.xopmc.galaxybridge.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EncryptedContentCacheRetentionTest {
    @Test
    fun pruneUsesInjectedClockAndPhysicallyRemovesOnlyExpiredRowsInATransaction() {
        val now = 31L * DAY
        val database = FakeRetentionDatabase(
            mutableListOf(
                Row("expired-healthy", now - 1, corrupt = false),
                Row("expired-corrupt", now, corrupt = true),
                Row("active-healthy", now + 1, corrupt = false),
                Row("active-corrupt", now + DAY, corrupt = true),
            ),
        )
        val maintenance = CacheRetentionMaintenance(clock = { now })

        val removed = maintenance.prune(database)

        assertEquals(2, removed)
        assertEquals(listOf("active-healthy", "active-corrupt"), database.rows.map(Row::id))
        assertEquals(listOf("begin", "delete:$now", "successful", "end"), database.events)
        assertFalse(database.rows.first { it.id == "active-healthy" }.corrupt)
        assertTrue(database.rows.first { it.id == "active-corrupt" }.corrupt)
    }

    @Test
    fun failedPruneEndsTransactionWithoutMarkingItSuccessful() {
        val database = FakeRetentionDatabase(mutableListOf(), failDelete = true)
        val maintenance = CacheRetentionMaintenance(clock = { 42 })

        val failure = runCatching { maintenance.prune(database) }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals(listOf("begin", "delete:42", "end"), database.events)
    }

    private data class Row(val id: String, val expiresAtMillis: Long, val corrupt: Boolean)

    private class FakeRetentionDatabase(
        val rows: MutableList<Row>,
        private val failDelete: Boolean = false,
    ) : CacheRetentionDatabase {
        val events = mutableListOf<String>()

        override fun beginTransaction() {
            events += "begin"
        }

        override fun deleteExpired(nowMillis: Long): Int {
            events += "delete:$nowMillis"
            if (failDelete) error("database unavailable")
            val before = rows.size
            rows.removeAll { it.expiresAtMillis <= nowMillis }
            return before - rows.size
        }

        override fun setTransactionSuccessful() {
            events += "successful"
        }

        override fun endTransaction() {
            events += "end"
        }
    }

    private companion object {
        const val DAY = 24L * 60 * 60 * 1_000
    }
}
