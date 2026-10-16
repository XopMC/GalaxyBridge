package com.xopmc.galaxybridge.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutomaticPermissionSetupTest {
    @Test fun firstLaunchRequestsOnePermissionAtATime() {
        val progress = AutomaticPermissionSetup()
        assertEquals(AutomaticSetupStep.Request(SetupAction.NearbyDevicesPermission), progress.next(missing, resumed = true))
        assertEquals(AutomaticSetupStep.Wait, progress.next(missing, resumed = true, inFlight = SetupAction.NearbyDevicesPermission))
    }

    @Test fun denialContinuesToUnrelatedPermissionsAndDoesNotRetryTheDeniedAction() {
        val afterDenial = AutomaticPermissionSetup().attempted(SetupAction.NearbyDevicesPermission)
        assertEquals(AutomaticSetupStep.Request(SetupAction.LocalNetworkPermission), afterDenial.next(missing, resumed = true))
        assertTrue(SetupAction.NearbyDevicesPermission in missing.runtimeQueue)
    }

    @Test fun rotationRestoresAttemptHistoryAndWaitsForTheExistingDialog() {
        val original = AutomaticPermissionSetup().attempted(SetupAction.NearbyDevicesPermission)
        val restored = AutomaticPermissionSetup.restore(original.savedAttempts, false, false)
        assertEquals(original, restored)
        assertEquals(AutomaticSetupStep.Wait, restored.next(missing, resumed = true, inFlight = SetupAction.NearbyDevicesPermission))
        assertEquals(AutomaticSetupStep.Request(SetupAction.LocalNetworkPermission), restored.next(missing, resumed = true))
    }

    @Test fun backgroundNeverLaunchesOrConsumesTheNextRequest() {
        val progress = AutomaticPermissionSetup()
        assertEquals(AutomaticSetupStep.Wait, progress.next(missing, resumed = false))
        assertTrue(progress.savedAttempts.isEmpty())
        assertEquals(AutomaticSetupStep.Request(SetupAction.NearbyDevicesPermission), progress.next(missing, resumed = true))
    }

    @Test fun allRuntimeResultsLeadToOneNotificationAccessGuide() {
        val progress = missing.runtimeQueue.fold(AutomaticPermissionSetup()) { state, action -> state.attempted(action) }
        assertEquals(AutomaticSetupStep.NotificationGuide, progress.next(missing, resumed = true))
        assertEquals(AutomaticSetupStep.Finish, progress.copy(notificationGuideOffered = true).next(missing, resumed = true))
    }

    @Test fun rejectingSpecialAccessAndResumingDoesNotOfferItAgain() {
        val progress = AutomaticPermissionSetup(missing.runtimeQueue.toSet(), notificationGuideOffered = true)
        repeat(4) { assertEquals(AutomaticSetupStep.Finish, progress.next(missing, resumed = true)) }
        assertTrue(missing.cards.any { it.action == SetupAction.NotificationListenerSettings })
    }

    @Test fun completingSetupDoesNotHideRevocationsOrAutomaticallyReRequestThem() {
        val progress = AutomaticPermissionSetup(completed = true)
        assertEquals(AutomaticSetupStep.Wait, progress.next(missing, resumed = true))
        assertTrue(missing.runtimeQueue.contains(SetupAction.CameraPermission))
        assertTrue(missing.cards.any { it.action == SetupAction.NotificationListenerSettings })
    }

    @Test fun grantedSpecialAccessSkipsGuideAndNoPairingIsInvented() {
        val pairingOnly = SetupState(listOf(SetupCard(SetupAction.PairMac, SetupKind.Pairing)), emptyList(), SetupStage.PairMac)
        assertEquals(AutomaticSetupStep.Finish, AutomaticPermissionSetup().next(pairingOnly, resumed = true))
        assertEquals(SetupStage.PairMac, pairingOnly.stage)
    }

    @Test fun restoredUnknownActionsNeverBecomeGrantsOrRequests() {
        val progress = AutomaticPermissionSetup.restore(setOf("CameraPermission", "future"), true, false)
        assertEquals(setOf("CameraPermission"), progress.savedAttempts)
        assertFalse(progress.completed)
    }

    @Test fun optionalCallRepairForAnExistingRoleHolderStaysExplicit() {
        val state = SetupStateResolver.resolve(optionalCallSnapshot)
        assertEquals(listOf(SetupAction.DialerRuntimePermissions), state.runtimeQueue)
        assertEquals(listOf(SetupAction.DialerRuntimePermissions), state.cards.map { it.action })
        assertEquals(AutomaticSetupStep.Finish, AutomaticPermissionSetup().next(state, resumed = true))
        assertFalse(AutomaticPermissionSetup().savedAttempts.contains(SetupAction.DialerRuntimePermissions.name))
    }

    @Test fun callRepairNeverBlocksOtherAutomaticPermissionsOrRepeatsAfterDenial() {
        val state = SetupStateResolver.resolve(optionalCallSnapshot.copy(
            selection = SetupSelection(setOf(SetupFeature.Calls, SetupFeature.Camera), true), cameraGranted = false,
        ))
        val initial = AutomaticPermissionSetup()
        assertEquals(AutomaticSetupStep.Request(SetupAction.CameraPermission), initial.next(state, resumed = true))
        val cameraAttempted = initial.attempted(SetupAction.CameraPermission)
        assertEquals(AutomaticSetupStep.Finish, cameraAttempted.next(state, resumed = true))
        val explicitCallDenied = cameraAttempted.attempted(SetupAction.DialerRuntimePermissions)
        assertEquals(AutomaticSetupStep.Finish, explicitCallDenied.next(state, resumed = true))
        assertTrue(state.cards.any { it.action == SetupAction.DialerRuntimePermissions })
    }

    private val optionalCallSnapshot = SetupSnapshot(
        apiLevel = 37, distribution = "direct", paired = true,
        localNetworkGranted = true, postNotificationsGranted = true, cameraGranted = true,
        recordAudioGranted = true, accessibilityEnabled = true, notificationListenerEnabled = true,
        safReadWriteGrantPersisted = true, dialerRoleHeld = true, callRuntimePermissionsGranted = false,
        selection = SetupSelection(setOf(SetupFeature.Calls), true),
    )

    private val missing = SetupState(
        cards = listOf(SetupCard(SetupAction.NotificationListenerSettings, SetupKind.SpecialAccess)),
        runtimeQueue = listOf(SetupAction.NearbyDevicesPermission, SetupAction.LocalNetworkPermission,
            SetupAction.PostNotificationsPermission, SetupAction.CameraPermission),
        stage = SetupStage.Permissions,
    )
}
