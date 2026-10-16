package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationGroupPresentationTest {
    private fun item(key: String, summary: Boolean = false, content: Boolean = false,
        group: String? = "android-group", pkg: String = "synthetic.qa", user: Int = 0,
        number: Int = 0) = NotificationGroupFacts(key, pkg, user, group, summary, content, number)

    @Test fun redundantSummaryLeavesOnlyRepresentedChildren() {
        assertEquals(setOf("one", "two", "three"), NotificationGroupPresentation.visibleKeys(listOf(
            item("one"), item("two"), item("three"), item("summary", summary = true),
        )))
    }

    @Test fun standaloneSummaryAndCustomOrMeaningfulSummaryRemainVisible() {
        val summary = item("summary", summary = true)
        assertEquals(setOf("summary"), NotificationGroupPresentation.visibleKeys(listOf(summary)))
        assertEquals(setOf("summary", "one"), NotificationGroupPresentation.visibleKeys(listOf(
            summary.copy(hasDistinctContent = true), item("one"),
        )))
        assertEquals(setOf("custom"), NotificationGroupPresentation.visibleKeys(listOf(item("custom", content = true))))
    }

    @Test fun childrenMustMatchGroupPackageAndAndroidUser() {
        val summary = item("summary", summary = true)
        for (child in listOf(item("one", group = "other"), item("one", pkg = "other"), item("one", user = 10))) {
            assertEquals(setOf("summary", "one"), NotificationGroupPresentation.visibleKeys(listOf(summary, child)))
        }
        assertEquals(setOf("summary", "one"), NotificationGroupPresentation.visibleKeys(listOf(
            summary.copy(groupKey = null), item("one", group = null),
        )))
    }

    @Test fun unrepresentedCountIsPreservedAndRepresentedCountIsRedundant() {
        assertEquals(setOf("summary", "one"), NotificationGroupPresentation.visibleKeys(listOf(
            item("summary", summary = true, number = 4), item("one"),
        )))
        assertEquals(setOf("one"), NotificationGroupPresentation.visibleKeys(listOf(
            item("summary", summary = true, number = 1), item("one"),
        )))
    }

    @Test fun snapshotsReconcileChildArrivalRemovalRegroupingAndReconnect() {
        val summary = item("summary", summary = true)
        val child = item("child")
        assertEquals(setOf("summary"), NotificationGroupPresentation.visibleKeys(listOf(summary)))
        assertEquals(setOf("child"), NotificationGroupPresentation.visibleKeys(listOf(summary, child)))
        assertEquals(setOf("summary"), NotificationGroupPresentation.visibleKeys(listOf(summary)))
        assertEquals(setOf("summary", "child"), NotificationGroupPresentation.visibleKeys(listOf(summary, child.copy(groupKey = "new"))))
        assertEquals(emptySet<String>(), NotificationGroupPresentation.visibleKeys(emptyList()))
    }

    @Test fun unchangedRankingBurstDoesNoPayloadWorkOrEmissionAndPostedKeysAlwaysInvalidate() {
        val conversions = mutableMapOf<String, Int>()
        val state = NotificationPresentationState<String> { a, b -> a == b }
        val keys = setOf("one", "two", "summary")
        fun convert(key: String): String {
            conversions[key] = (conversions[key] ?: 0) + 1
            return key
        }
        state.payloads(keys, emptySet(), ::convert)
        assertEquals(2, state.present(setOf("one", "two")).changed.size)
        repeat(200) {
            state.payloads(keys, emptySet(), ::convert)
            val delta = state.present(setOf("one", "two"))
            assertEquals(emptyList<String>(), delta.changed)
            assertEquals(emptyList<String>(), delta.removed)
        }
        assertEquals(mapOf("one" to 1, "two" to 1, "summary" to 1), conversions)
        state.payloads(keys, setOf("one")) { key -> convert(key) + " updated" }
        assertEquals(listOf("one updated"), state.present(setOf("one", "two")).changed)
        assertEquals(mapOf("one" to 2, "two" to 1, "summary" to 1), conversions)
        // Group metadata can reveal a cached summary without another icon/content conversion.
        assertEquals(listOf("summary"), state.present(setOf("one", "two", "summary")).changed)
    }

    @Test fun removedPayloadsArePrunedAndReconnectHasNoStalePresentation() {
        val state = NotificationPresentationState<String> { a, b -> a == b }
        state.payloads(setOf("one"), emptySet()) { "first" }
        state.present(setOf("one"))
        assertEquals(emptyMap<String, String>(), state.payloads(emptySet(), emptySet()) { error("unexpected") })
        assertEquals(listOf("first"), state.present(emptySet()).removed)
        assertEquals(emptyList<String>(), state.present(emptySet()).removed)
        state.payloads(setOf("one"), emptySet()) { "second" }
        assertEquals(listOf("second"), state.present(setOf("one")).changed)
        state.clear()
        state.payloads(setOf("one"), emptySet()) { "reconnected" }
        assertEquals(listOf("reconnected"), state.present(setOf("one")).changed)
    }
}
