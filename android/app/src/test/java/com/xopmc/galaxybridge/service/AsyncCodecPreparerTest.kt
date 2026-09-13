package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class AsyncCodecPreparerTest {
    @Test
    fun `registers callback before configure surface creation and start`() {
        val fixture = Fixture()

        val prepared = fixture.preparer().prepare { codec, thread ->
            fixture.events += "callback:${codec.name}:${thread.name}"
        }

        assertEquals(
            listOf("create-codec", "start-thread", "callback:codec:thread", "configure", "surface", "start"),
            fixture.events,
        )
        assertEquals("codec", prepared?.codec?.name)
        assertEquals("surface", prepared?.surface?.name)
        assertEquals("thread", prepared?.callbackThread?.name)
        assertFalse(fixture.codecReleased)
        assertFalse(fixture.surfaceReleased)
        assertFalse(fixture.threadQuit)
    }

    @Test
    fun `callback registration failure releases codec and callback thread`() {
        val fixture = Fixture()

        val prepared = fixture.preparer().prepare { _, _ -> error("callback failed") }

        assertNull(prepared)
        assertEquals(
            listOf("create-codec", "start-thread", "preparation-failed", "release-codec", "quit-thread"),
            fixture.events,
        )
        assertTrue(fixture.codecReleased)
        assertTrue(fixture.threadQuit)
        assertFalse(fixture.surfaceReleased)
    }

    @Test
    fun `configure failure releases codec and callback thread`() {
        val fixture = Fixture(failAt = "configure")

        val prepared = fixture.preparer().prepare { _, _ -> fixture.events += "callback" }

        assertNull(prepared)
        assertEquals(
            listOf(
                "create-codec",
                "start-thread",
                "callback",
                "configure",
                "preparation-failed",
                "release-codec",
                "quit-thread",
            ),
            fixture.events,
        )
        assertTrue(fixture.codecReleased)
        assertTrue(fixture.threadQuit)
        assertFalse(fixture.surfaceReleased)
    }

    @Test
    fun `surface creation failure releases codec and callback thread`() {
        val fixture = Fixture(failAt = "surface")

        val prepared = fixture.preparer().prepare { _, _ -> fixture.events += "callback" }

        assertNull(prepared)
        assertEquals(
            listOf(
                "create-codec",
                "start-thread",
                "callback",
                "configure",
                "surface",
                "preparation-failed",
                "release-codec",
                "quit-thread",
            ),
            fixture.events,
        )
        assertTrue(fixture.codecReleased)
        assertTrue(fixture.threadQuit)
        assertFalse(fixture.surfaceReleased)
    }

    @Test
    fun `start failure releases surface codec and callback thread`() {
        val fixture = Fixture(failAt = "start")

        val prepared = fixture.preparer().prepare { _, _ -> fixture.events += "callback" }

        assertNull(prepared)
        assertEquals(
            listOf(
                "create-codec",
                "start-thread",
                "callback",
                "configure",
                "surface",
                "start",
                "preparation-failed",
                "release-surface",
                "stop-codec",
                "release-codec",
                "quit-thread",
            ),
            fixture.events,
        )
        assertTrue(fixture.surfaceReleased)
        assertTrue(fixture.codecStopped)
        assertTrue(fixture.codecReleased)
        assertTrue(fixture.threadQuit)
    }

    @Test
    fun `codec release failure is surfaced after callback thread cleanup`() {
        val fixture = Fixture(failAt = "configure", cleanupFailures = setOf("release-codec"))

        val failure = assertThrows(AsyncCodecPreparationCleanupException::class.java) {
            fixture.preparer().prepare { _, _ -> fixture.events += "callback" }
        }

        assertEquals("release-codec failed", failure.cause?.message)
        assertEquals(
            listOf(
                "create-codec",
                "start-thread",
                "callback",
                "configure",
                "preparation-failed",
                "release-codec",
                "quit-thread",
            ),
            fixture.events,
        )
        assertTrue(fixture.threadQuit)
    }

    @Test
    fun `all cleanup is attempted and every cleanup failure is retained`() {
        val fixture = Fixture(
            failAt = "start",
            cleanupFailures = setOf(
                "preparation-failed",
                "release-surface",
                "stop-codec",
                "release-codec",
                "quit-thread",
            ),
        )

        val failure = assertThrows(AsyncCodecPreparationCleanupException::class.java) {
            fixture.preparer().prepare { _, _ -> fixture.events += "callback" }
        }

        assertEquals(5, 1 + failure.suppressed.size)
        assertEquals(
            listOf(
                "preparation-failed",
                "release-surface",
                "stop-codec",
                "release-codec",
                "quit-thread",
            ),
            fixture.events.takeLast(5),
        )
    }

    private data class Codec(val name: String = "codec")
    private data class Surface(val name: String = "surface")
    private data class CallbackThread(val name: String = "thread")

    private class Fixture(
        private val failAt: String? = null,
        private val cleanupFailures: Set<String> = emptySet(),
    ) {
        val events = mutableListOf<String>()
        var codecStopped = false
        var codecReleased = false
        var surfaceReleased = false
        var threadQuit = false

        fun preparer() = AsyncCodecPreparer(
            createCodec = {
                events += "create-codec"
                Codec()
            },
            startCallbackThread = {
                events += "start-thread"
                CallbackThread()
            },
            configureCodec = {
                events += "configure"
                failIfRequested("configure")
            },
            createInputSurface = {
                events += "surface"
                failIfRequested("surface")
                Surface()
            },
            startCodec = {
                events += "start"
                failIfRequested("start")
            },
            stopCodec = {
                events += "stop-codec"
                codecStopped = true
                failCleanupIfRequested("stop-codec")
            },
            releaseCodec = {
                events += "release-codec"
                codecReleased = true
                failCleanupIfRequested("release-codec")
            },
            releaseSurface = {
                events += "release-surface"
                surfaceReleased = true
                failCleanupIfRequested("release-surface")
            },
            quitCallbackThread = {
                events += "quit-thread"
                threadQuit = true
                failCleanupIfRequested("quit-thread")
            },
            onPreparationFailure = {
                events += "preparation-failed"
                failCleanupIfRequested("preparation-failed")
            },
        )

        private fun failIfRequested(step: String) {
            if (failAt == step) error("$step failed")
        }

        private fun failCleanupIfRequested(step: String) {
            if (step in cleanupFailures) error("$step failed")
        }
    }
}
