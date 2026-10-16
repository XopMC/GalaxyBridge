package com.xopmc.galaxybridge.service

/** Facts come from StatusBarNotification, never from app/package name heuristics. */
internal data class NotificationGroupFacts(
    val key: String,
    val packageName: String,
    val userId: Int,
    val groupKey: String?,
    val isSummary: Boolean,
    val hasDistinctContent: Boolean,
    val number: Int = 0,
)

internal object NotificationGroupPresentation {
    fun visibleKeys(notifications: Collection<NotificationGroupFacts>): Set<String> =
        notifications.filter { candidate ->
            if (!candidate.isSummary || candidate.hasDistinctContent || candidate.groupKey == null) return@filter true
            val children = notifications.count {
                !it.isSummary && it.packageName == candidate.packageName &&
                    it.userId == candidate.userId && it.groupKey == candidate.groupKey
            }
            // A summary may describe additional messages which have no individual row.
            children == 0 || candidate.number > children
        }.mapTo(linkedSetOf()) { it.key }
}

internal data class NotificationPresentationDelta<T>(
    val visible: Map<String, T>,
    val changed: List<T>,
    val removed: List<T>,
)

/** Payload work is invalidated by posted keys; grouping-only ranking updates reuse it. */
internal class NotificationPresentationState<T>(private val same: (T, T) -> Boolean) {
    private val payloads = linkedMapOf<String, T>()
    private var presented = emptyMap<String, T>()

    fun payloads(keys: Set<String>, invalidated: Set<String>, convert: (String) -> T): Map<String, T> {
        payloads.keys.retainAll(keys)
        keys.forEach { key ->
            if (key in invalidated || key !in payloads) payloads[key] = convert(key)
        }
        return payloads.toMap()
    }

    fun present(visibleKeys: Set<String>): NotificationPresentationDelta<T> {
        val visible = payloads.filterKeys { it in visibleKeys }
        val changed = visible.filter { (key, row) -> presented[key]?.let { !same(it, row) } ?: true }.values.toList()
        val removed = presented.filterKeys { it !in visible }.values.toList()
        presented = visible
        return NotificationPresentationDelta(visible, changed, removed)
    }

    fun clear() {
        payloads.clear()
        presented = emptyMap()
    }
}
