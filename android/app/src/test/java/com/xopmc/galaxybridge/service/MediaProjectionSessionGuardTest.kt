package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaProjectionSessionGuardTest {
    @Test
    fun projectionAvailabilityPreservesTheLockReasonAcrossServiceCleanup() {
        val availability = ProjectionAvailabilityTracker()
        assertEquals("media_projection_consent_required", availability.unavailableReason)

        availability.captureStarted()
        assertTrue(availability.capturing)
        assertEquals(null, availability.unavailableReason)

        availability.projectionStopped(deviceLocked = true)
        assertTrue(!availability.capturing)
        assertEquals("media_projection_stopped_when_device_locked", availability.unavailableReason)

        availability.captureEnded()
        assertEquals(
            "media_projection_stopped_when_device_locked",
            availability.unavailableReason,
        )

        availability.captureStarted()
        assertTrue(availability.capturing)
        assertEquals(null, availability.unavailableReason)
    }

    @Test
    fun staleStopCallbackCannotStopReplacementCapture() {
        val guard = MediaProjectionSessionGuard()
        var stops = 0

        val oldSession = guard.beginSession()
        guard.invalidateCurrentSession()
        val replacementSession = guard.beginSession()

        guard.runIfCurrent(oldSession) { stops += 1 }
        assertEquals(0, stops)

        guard.runIfCurrent(replacementSession) { stops += 1 }
        assertEquals(1, stops)
    }

    @Test
    fun retiredCodecCallbacksCannotAffectReplacementSession() {
        val guard = MediaProjectionCodecSessionGuard<Any>()
        val oldCodec = Any()
        val replacementCodec = Any()
        val oldSession = guard.beginSession(oldCodec, epoch = 7)
        val replacementSession = guard.beginSession(replacementCodec, epoch = 8)
        var staleOutputs = 0
        var staleFormats = 0
        var staleErrors = 0
        var releases = 0

        guard.handleOutput(
            oldSession,
            oldCodec,
            releaseOutput = { releases += 1 },
            onCurrentReleaseFailure = { error -> throw error },
        ) { staleOutputs += 1 }
        guard.handleFormat(oldSession, oldCodec) { staleFormats += 1 }
        guard.handleError(oldSession, oldCodec) { staleErrors += 1 }

        assertEquals(0, staleOutputs)
        assertEquals(0, staleFormats)
        assertEquals(0, staleErrors)
        assertEquals(1, releases)

        var currentErrors = 0
        guard.handleError(replacementSession, replacementCodec) { currentErrors += 1 }
        assertEquals(1, currentErrors)
    }

    @Test
    fun currentCodecOutputUsesItsCapturedSessionEpochAndAlwaysReleases() {
        val guard = MediaProjectionCodecSessionGuard<Any>()
        val codec = Any()
        val session = guard.beginSession(codec, epoch = 41)
        var observedEpoch = 0
        var releases = 0
        var releaseFailures = 0

        guard.handleOutput(session, codec, releaseOutput = {
            releases += 1
            error("codec was already released")
        }, onCurrentReleaseFailure = {
            releaseFailures += 1
        }) { capturedEpoch ->
            observedEpoch = capturedEpoch
        }

        assertEquals(41, observedEpoch)
        assertEquals(1, releases)
        assertEquals(1, releaseFailures)
        assertTrue(guard.isCurrent(session, codec))
    }

    @Test
    fun staleCodecOutputReleaseFailureCannotAffectReplacementSession() {
        val guard = MediaProjectionCodecSessionGuard<Any>()
        val retiredCodec = Any()
        val retiredSession = guard.beginSession(retiredCodec, epoch = 41)
        val replacementCodec = Any()
        val replacementSession = guard.beginSession(replacementCodec, epoch = 42)
        var releaseFailures = 0

        guard.handleOutput(
            retiredSession,
            retiredCodec,
            releaseOutput = { error("retired codec release failed") },
            onCurrentReleaseFailure = { releaseFailures += 1 },
        ) { error("stale output emitted") }

        assertEquals(0, releaseFailures)
        assertTrue(guard.isCurrent(replacementSession, replacementCodec))
    }

    @Test
    fun callbackCodecMustMatchCurrentSessionCodec() {
        val guard = MediaProjectionCodecSessionGuard<Any>()
        val currentCodec = Any()
        val wrongCodec = Any()
        val session = guard.beginSession(currentCodec, epoch = 12)
        var outputs = 0
        var formats = 0
        var errors = 0
        var releases = 0

        guard.handleOutput(
            session,
            wrongCodec,
            releaseOutput = { releases += 1 },
            onCurrentReleaseFailure = { error -> throw error },
        ) { outputs += 1 }
        guard.handleFormat(session, wrongCodec) { formats += 1 }
        guard.handleError(session, wrongCodec) { errors += 1 }

        assertEquals(0, outputs)
        assertEquals(0, formats)
        assertEquals(0, errors)
        assertEquals(1, releases)
        assertTrue(!guard.isCurrent(session, wrongCodec))
    }
}
