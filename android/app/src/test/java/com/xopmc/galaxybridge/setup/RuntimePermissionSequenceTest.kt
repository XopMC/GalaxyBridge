package com.xopmc.galaxybridge.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RuntimePermissionSequenceTest {
    @Test(expected = IllegalArgumentException::class)
    fun doubleTapCannotLaunchAnotherDialogWhileOneIsOpen() {
        RuntimePermissionRequestGate().begin(SetupAction.CameraPermission).begin(SetupAction.RecordAudioPermission)
    }

    @Test
    fun completionHasNoPendingRequestAndExplicitRetryRemainsPossible() {
        val completed = RuntimePermissionRequestGate().begin(SetupAction.CameraPermission).complete()
        assertNull(completed.inFlight)
        assertEquals(SetupAction.CameraPermission, completed.begin(SetupAction.CameraPermission).inFlight)
    }

    @Test
    fun restoredActivityWaitsForTheAlreadyOpenedDialogResult() {
        val original = RuntimePermissionRequestGate().begin(SetupAction.CameraPermission)
        val restored = RuntimePermissionRequestGate(original.inFlight)
        assertEquals(original, restored)
        assertNull(restored.complete().inFlight)
    }
}
