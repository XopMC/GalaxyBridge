package com.xopmc.galaxybridge.service

internal data class NotificationMessageText(val sender: CharSequence?, val text: CharSequence?)

internal data class NotificationTextInput(
    val appLabel: CharSequence,
    val title: CharSequence? = null,
    val bigTitle: CharSequence? = null,
    val conversationTitle: CharSequence? = null,
    val text: CharSequence? = null,
    val bigText: CharSequence? = null,
    val textLines: List<CharSequence?> = emptyList(),
    val messages: List<NotificationMessageText> = emptyList(),
    val subText: CharSequence? = null,
    val summaryText: CharSequence? = null,
    val ticker: CharSequence? = null,
)

internal data class NotificationTextContent(val title: String, val body: String)

/** Extracts standard Android content without excluding opaque custom notifications. */
internal object NotificationTextExtractor {
    const val MAX_TITLE_CHARS = 512
    const val MAX_BODY_CHARS = 8_192
    const val MAX_ENTRIES = 20

    fun extract(input: NotificationTextInput): NotificationTextContent {
        val title = firstText(MAX_TITLE_CHARS, input.title, input.bigTitle, input.conversationTitle, input.appLabel)
        val messages = input.messages.takeLast(MAX_ENTRIES).mapNotNull {
            val text = bounded(it.text, MAX_BODY_CHARS)
            if (text.isEmpty()) null else {
                val sender = bounded(it.sender, 256)
                if (sender.isEmpty()) text else "$sender: $text"
            }
        }
        val body = firstText(
            MAX_BODY_CHARS,
            joinRecent(messages),
            input.bigText,
            joinRecent(input.textLines),
            input.text,
            input.subText,
            input.summaryText,
            input.ticker,
        )
        return NotificationTextContent(title, body)
    }

    private fun firstText(limit: Int, vararg values: CharSequence?): String {
        for (value in values) {
            val text = bounded(value, limit)
            if (text.isNotEmpty()) return text
        }
        return ""
    }

    private fun joinRecent(values: List<CharSequence?>): String {
        var remaining = MAX_BODY_CHARS
        val result = mutableListOf<String>()
        for (value in values.takeLast(MAX_ENTRIES).asReversed()) {
            val text = bounded(value, remaining)
            if (text.isEmpty()) continue
            result += text
            remaining -= text.length + 1
            if (remaining <= 0) break
        }
        return result.asReversed().joinToString("\n")
    }

    private fun bounded(value: CharSequence?, limit: Int): String {
        if (value == null || limit <= 0) return ""
        var end = minOf(value.length, limit)
        if (end > 0 && end < value.length && Character.isHighSurrogate(value[end - 1])) end -= 1
        return value.subSequence(0, end).toString().trim()
    }
}
