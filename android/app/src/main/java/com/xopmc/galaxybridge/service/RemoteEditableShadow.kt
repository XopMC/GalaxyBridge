package com.xopmc.galaxybridge.service

internal data class EditorSnapshot(
    val text: String,
    val selectionStart: Int,
    val selectionEnd: Int,
)

/**
 * Keeps the result of a successful remote ACTION_SET_TEXT until Android's
 * Accessibility snapshot catches up. Some Samsung/Google editors expose the
 * pre-edit node for several frames; trusting it would make the next LAN text
 * packet overwrite the previous one.
 */
internal class RemoteEditableShadow(
    private val expiryMillis: Long,
) {
    private var editorKey: String? = null
    private var text = ""
    private var selectionStart = 0
    private var selectionEnd = 0
    private var appliedAtMillis = Long.MIN_VALUE

    @Synchronized
    fun resolve(
        editorKey: String,
        observedText: String,
        observedSelectionStart: Int,
        observedSelectionEnd: Int,
        nowMillis: Long,
    ): EditorSnapshot {
        val observedSelection = validSelection(
            observedText,
            observedSelectionStart,
            observedSelectionEnd,
        )
        val isCurrent = this.editorKey == editorKey &&
            nowMillis - appliedAtMillis <= expiryMillis
        if (!isCurrent) {
            invalidateLocked()
            val selection = observedSelection ?: (observedText.length to observedText.length)
            return EditorSnapshot(observedText, selection.first, selection.second)
        }

        if (observedText == text) {
            if (observedSelection != null) {
                selectionStart = observedSelection.first
                selectionEnd = observedSelection.second
            }
            return EditorSnapshot(text, selectionStart, selectionEnd)
        }

        return EditorSnapshot(text, selectionStart, selectionEnd)
    }

    @Synchronized
    fun applied(
        editorKey: String,
        edit: TextEditResult,
        nowMillis: Long,
    ) {
        this.editorKey = editorKey
        text = edit.text
        selectionStart = edit.selection.coerceIn(0, edit.text.length)
        selectionEnd = selectionStart
        appliedAtMillis = nowMillis
    }

    @Synchronized
    fun selected(
        editorKey: String,
        observedText: String,
        selectionStart: Int,
        selectionEnd: Int,
        nowMillis: Long,
    ) {
        val selection = validSelection(observedText, selectionStart, selectionEnd) ?: return
        this.editorKey = editorKey
        text = observedText
        this.selectionStart = selection.first
        this.selectionEnd = selection.second
        appliedAtMillis = nowMillis
    }

    @Synchronized
    fun invalidate() = invalidateLocked()

    private fun validSelection(text: String, start: Int, end: Int): Pair<Int, Int>? =
        if (start in 0..text.length && end in 0..text.length) {
            minOf(start, end) to maxOf(start, end)
        } else {
            null
        }

    private fun invalidateLocked() {
        editorKey = null
        text = ""
        selectionStart = 0
        selectionEnd = 0
        appliedAtMillis = Long.MIN_VALUE
    }
}
