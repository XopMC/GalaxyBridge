package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationTextExtractorTest {
    @Test fun expandedTextSurvivesMissingCollapsedText() {
        val result = NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Google", bigTitle = "Weather", bigText = "Rain ends at 18:00"))
        assertEquals("Weather", result.title)
        assertEquals("Rain ends at 18:00", result.body)
    }

    @Test fun expandedTextPreservesContentBeyondCollapsedPreview() {
        val result = NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Mail", title = "New email", text = "First sentence…", bigText = "First sentence.\nSecond sentence."))
        assertEquals("First sentence.\nSecond sentence.", result.body)
    }

    @Test fun inboxLinesAndConversationMessagesRemainReadable() {
        val inbox = NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Mail", textLines = listOf(" Alice: Hello ", "", "Bob: Thanks")))
        assertEquals("Alice: Hello\nBob: Thanks", inbox.body)
        val conversation = NotificationTextExtractor.extract(NotificationTextInput(
            appLabel = "Messages", conversationTitle = "Family", text = "Latest preview",
            messages = listOf(NotificationMessageText("Alice", "Hello"), NotificationMessageText("Bob", "Thanks")),
        ))
        assertEquals("Family", conversation.title)
        assertEquals("Alice: Hello\nBob: Thanks", conversation.body)
    }

    @Test fun blankRichFieldsFallBackToAvailableStandardText() {
        val result = NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Calendar", title = " Meeting ", text = "Starts now", bigText = " \n", messages = listOf(NotificationMessageText("Alice", "  ")), textLines = listOf("")))
        assertEquals("Meeting", result.title)
        assertEquals("Starts now", result.body)
    }

    @Test fun subtextSummaryAndTickerProvideFallbackWithoutInventingContent() {
        assertEquals("Download complete", NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Downloads", subText = "Download complete", ticker = "Ticker")).body)
        assertEquals("3 updates", NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Google", summaryText = "3 updates")).body)
        assertEquals("Now playing", NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Music", ticker = "Now playing")).body)
        val custom = NotificationTextExtractor.extract(NotificationTextInput(appLabel = "Custom app"))
        assertEquals("Custom app", custom.title)
        assertEquals("", custom.body)
    }

    @Test fun historyAndPayloadsHaveFiniteSizeAndKeepTheNewestMessages() {
        val result = NotificationTextExtractor.extract(NotificationTextInput(
            appLabel = "Messages", title = "T".repeat(10_000),
            messages = (0..<100).map { NotificationMessageText("Sender", "message-$it") },
        ))
        assertTrue(result.title.length <= 512)
        assertEquals(20, result.body.lines().size)
        assertFalse(result.body.contains("message-79"))
        assertTrue(result.body.endsWith("message-99"))
        val huge = NotificationTextExtractor.extract(NotificationTextInput(appLabel = "App", bigText = "🙂".repeat(10_000)))
        assertTrue(huge.body.length <= 8_192)
        assertFalse(Character.isHighSurrogate(huge.body.last()))
        val longMessage = NotificationTextExtractor.extract(NotificationTextInput(
            appLabel = "Messages", messages = listOf(NotificationMessageText("Sender", "A".repeat(3_000) + "tail")),
        ))
        assertTrue("A single message below the body budget should retain its full text", longMessage.body.endsWith("tail"))
    }
}
