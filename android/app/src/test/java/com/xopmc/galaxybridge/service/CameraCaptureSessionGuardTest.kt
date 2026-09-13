package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraCaptureSessionGuardTest {
    @Test
    fun staleCameraProviderAndSurfaceCallbacksCannotReviveAStoppedCapture() {
        val guard = CameraCaptureSessionGuard()
        val old = guard.beginSession(epoch = 4)
        guard.invalidateCurrentSession()
        val replacement = guard.beginSession(epoch = 5)
        var callbacks = 0

        guard.runIfCurrent(old) { callbacks += 1 }
        assertEquals(0, callbacks)
        assertFalse(guard.isCurrent(old))

        guard.runIfCurrent(replacement) { callbacks += 1 }
        assertEquals(1, callbacks)
        assertTrue(guard.isCurrent(replacement))
        assertEquals(5, replacement.epoch)
    }

    @Test
    fun staleEncoderCallbacksCannotStopOrPublishIntoAReplacementSurface() {
        val guard = CameraEncoderSessionGuard<Any>()
        val oldCodec = Any()
        val replacementCodec = Any()
        val old = guard.beginSession(oldCodec, epoch = 12)
        val replacement = guard.beginSession(replacementCodec, epoch = 13)
        var outputs = 0
        var stops = 0
        var releases = 0

        guard.handleOutput(old, oldCodec, releaseOutput = { releases += 1 }) { outputs += 1 }
        guard.runIfCurrent(old, oldCodec) { stops += 1 }
        assertEquals(0, outputs)
        assertEquals(0, stops)
        assertEquals(1, releases)

        guard.handleOutput(replacement, replacementCodec, releaseOutput = { releases += 1 }) { epoch ->
            assertEquals(13, epoch)
            outputs += 1
        }
        guard.runIfCurrent(replacement, replacementCodec) { stops += 1 }
        assertEquals(1, outputs)
        assertEquals(1, stops)
        assertEquals(2, releases)
    }
}
