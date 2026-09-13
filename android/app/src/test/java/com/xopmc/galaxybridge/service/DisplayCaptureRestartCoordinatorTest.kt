package com.xopmc.galaxybridge.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DisplayCaptureRestartCoordinatorTest {
    private val portrait = CaptureDisplaySpec(width = 1_080, height = 2_340, densityDpi = 480)
    private val landscape = CaptureDisplaySpec(width = 2_340, height = 1_080, densityDpi = 480)
    private val unfolded = CaptureDisplaySpec(width = 1_812, height = 2_176, densityDpi = 420)

    @Test
    fun unchangedDisplayIsDeduplicatedWithoutSchedulingRestart() {
        val coordinator = DisplayCaptureRestartCoordinator(debounceMillis = 150)
        val initial = coordinator.beginCapture(portrait)

        assertEquals(1, initial.epoch)
        assertEquals(portrait, initial.spec)
        assertEquals(
            DisplayCaptureRestartCoordinator.Observation.Ignored,
            coordinator.observe(initial.captureGeneration, portrait, nowMillis = 1_000),
        )
    }

    @Test
    fun repeatedDisplayNotificationKeepsOneDebouncedRestart() {
        val coordinator = DisplayCaptureRestartCoordinator(debounceMillis = 150)
        val initial = coordinator.beginCapture(portrait)

        val scheduled = coordinator.observe(initial.captureGeneration, landscape, nowMillis = 1_000)
        assertTrue(scheduled is DisplayCaptureRestartCoordinator.Observation.Schedule)
        val request = (scheduled as DisplayCaptureRestartCoordinator.Observation.Schedule).request
        assertEquals(1_150, request.dueAtMillis)
        assertEquals(
            DisplayCaptureRestartCoordinator.Observation.Ignored,
            coordinator.observe(initial.captureGeneration, landscape, nowMillis = 1_025),
        )

        val restart = coordinator.commit(request)
        assertEquals(2, restart?.epoch)
        assertEquals(landscape, restart?.spec)
    }

    @Test
    fun newerFoldGeometrySupersedesStaleDebounceCallback() {
        val coordinator = DisplayCaptureRestartCoordinator(debounceMillis = 150)
        val initial = coordinator.beginCapture(portrait)
        val rotation = coordinator.observe(initial.captureGeneration, landscape, nowMillis = 1_000)
            as DisplayCaptureRestartCoordinator.Observation.Schedule
        val fold = coordinator.observe(initial.captureGeneration, unfolded, nowMillis = 1_040)
            as DisplayCaptureRestartCoordinator.Observation.Schedule

        assertNull(coordinator.commit(rotation.request))
        val restart = coordinator.commit(fold.request)
        assertEquals(2, restart?.epoch)
        assertEquals(unfolded, restart?.spec)
    }

    @Test
    fun returningToActiveGeometryCancelsPendingRestartAndItsCallback() {
        val coordinator = DisplayCaptureRestartCoordinator(debounceMillis = 150)
        val initial = coordinator.beginCapture(portrait)
        val scheduled = coordinator.observe(initial.captureGeneration, landscape, nowMillis = 1_000)
            as DisplayCaptureRestartCoordinator.Observation.Schedule

        assertEquals(
            DisplayCaptureRestartCoordinator.Observation.CancelPending,
            coordinator.observe(initial.captureGeneration, portrait, nowMillis = 1_050),
        )
        assertNull(coordinator.commit(scheduled.request))
    }

    @Test
    fun replacementProjectionInvalidatesOldDisplayCallbacksAndKeepsEpochMonotonic() {
        val coordinator = DisplayCaptureRestartCoordinator(debounceMillis = 150)
        val oldCapture = coordinator.beginCapture(portrait)
        val oldRequest = coordinator.observe(oldCapture.captureGeneration, landscape, nowMillis = 1_000)
            as DisplayCaptureRestartCoordinator.Observation.Schedule

        coordinator.invalidateCapture()
        val replacement = coordinator.beginCapture(unfolded)

        assertTrue(replacement.captureGeneration > oldCapture.captureGeneration)
        assertEquals(2, replacement.epoch)
        assertNull(coordinator.commit(oldRequest.request))
        assertEquals(
            DisplayCaptureRestartCoordinator.Observation.Ignored,
            coordinator.observe(oldCapture.captureGeneration, landscape, nowMillis = 1_200),
        )
    }
}
