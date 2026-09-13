package com.xopmc.galaxybridge.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupStateResolverTest {
    @Test
    fun hidesGrantedItemsAndNeverModelsMediaProjectionAsPersistentPermission() {
        val state = SetupStateResolver.resolve(
            readySnapshot.copy(
                paired = false,
                notificationListenerEnabled = false,
            ),
        )

        assertEquals(
            listOf(
                SetupAction.NotificationListenerSettings,
                SetupAction.PairMac,
            ),
            state.cards.map { it.action },
        )
        assertFalse(state.cards.map { it.action.name }.any { it.contains("Projection") || it.contains("Screen") })
    }

    @Test
    fun runtimeQueueIsSequentialAndContainsOnlyOrdinaryPermissionRequests() {
        val state = SetupStateResolver.resolve(
            readySnapshot.copy(
                distribution = "internal",
                apiLevel = 37,
                localNetworkGranted = false,
                postNotificationsGranted = false,
                cameraGranted = false,
                recordAudioGranted = false,
                accessibilityEnabled = false,
                dialerRoleHeld = true,
                callRuntimePermissionsGranted = false,
            ),
        )

        assertEquals(
            listOf(
                SetupAction.LocalNetworkPermission,
                SetupAction.PostNotificationsPermission,
                SetupAction.CameraPermission,
                SetupAction.RecordAudioPermission,
                SetupAction.DialerRuntimePermissions,
            ),
            state.runtimeQueue,
        )
    }

    @Test
    fun playDistributionNeverOffersDefaultDialerOrCallPermissions() {
        val state = SetupStateResolver.resolve(
            readySnapshot.copy(
                distribution = "play",
                dialerRoleHeld = false,
                callRuntimePermissionsGranted = false,
            ),
        )

        assertTrue(state.cards.isEmpty())
        assertFalse(state.cards.any { it.action == SetupAction.DialerRuntimePermissions })
        assertFalse(state.runtimeQueue.any { it == SetupAction.DialerRuntimePermissions })
    }

    @Test
    fun freshInternalInstallNeverOffersToReplaceTheDefaultPhoneApp() {
        val state = SetupStateResolver.resolve(
            readySnapshot.copy(
                distribution = "internal",
                dialerRoleHeld = false,
                callRuntimePermissionsGranted = false,
            ),
        )

        assertTrue(state.cards.isEmpty())
        assertFalse(state.cards.any { it.action == SetupAction.DialerRuntimePermissions })
        assertFalse(state.runtimeQueue.any { it == SetupAction.DialerRuntimePermissions })
    }

    @Test
    fun internalInstallWithDialerRoleAlreadyHeldOffersOnlyMissingCallPermissions() {
        val state = SetupStateResolver.resolve(
            readySnapshot.copy(
                distribution = "internal",
                dialerRoleHeld = true,
                callRuntimePermissionsGranted = false,
            ),
        )

        assertEquals(listOf(SetupAction.DialerRuntimePermissions), state.cards.map { it.action })
        assertEquals(listOf(SetupAction.DialerRuntimePermissions), state.runtimeQueue)
    }

    @Test
    fun directInstallWithDialerRoleAlreadyHeldOffersOnlyMissingCallPermissions() {
        val state = SetupStateResolver.resolve(
            readySnapshot.copy(
                distribution = "direct",
                dialerRoleHeld = true,
                callRuntimePermissionsGranted = false,
            ),
        )

        assertEquals(listOf(SetupAction.DialerRuntimePermissions), state.cards.map { it.action })
        assertEquals(listOf(SetupAction.DialerRuntimePermissions), state.runtimeQueue)
    }

    @Test
    fun smsRoleIsNotPartOfSetup() {
        val state = SetupStateResolver.resolve(
            readySnapshot.copy(
                notificationListenerEnabled = false,
            ),
        )

        assertFalse(state.cards.map { it.action.name }.any { it.contains("Sms", ignoreCase = true) })
        assertFalse(state.runtimeQueue.map { it.name }.any { it.contains("Sms", ignoreCase = true) })
    }

    @Test
    fun keyboardIsNeverRequiredBySetupAndSamsungKeyboardCanRemainDefault() {
        val state = SetupStateResolver.resolve(
            readySnapshot,
        )

        assertFalse(state.cards.any { it.action.name.startsWith("InputMethod") })
        assertFalse(state.runtimeQueue.any { it.name.startsWith("InputMethod") })
    }

    @Test
    fun safPickerStartsInSelectableDocumentsFolderInsteadOfRestrictedDownloadRoot() {
        assertEquals(
            "content://com.android.externalstorage.documents/document/primary%3ADocuments",
            SafInitialLocation.documentsUri,
        )
        assertTrue(SafInitialLocation.documentsUri.endsWith("primary%3ADocuments"))
        assertFalse(SafInitialLocation.documentsUri.endsWith("primary%3ADownload"))
    }

    @Test
    fun firstLaunchAndUnconfirmedChoicesNeverRequestAnyPermission() {
        for (selection in listOf(SetupSelection(), SetupSelection(setOf(SetupFeature.Camera)))) {
            val state = SetupStateResolver.resolve(readySnapshot.copy(
                selection = selection, paired = false, cameraGranted = false,
                recordAudioGranted = false, postNotificationsGranted = false,
            ))
            assertTrue(state.cards.isEmpty())
            assertTrue(state.runtimeQueue.isEmpty())
            assertEquals(SetupStage.ChooseFeatures, state.stage)
        }
    }

    @Test
    fun onlyTheSelectedFunctionDeterminesMissingPermissionCards() {
        val missing = readySnapshot.copy(cameraGranted = false, recordAudioGranted = false,
            postNotificationsGranted = false, notificationListenerEnabled = false,
            accessibilityEnabled = false, safReadWriteGrantPersisted = false)
        val expected = mapOf(
            SetupFeature.Files to emptyList(),
            SetupFeature.Notifications to listOf(SetupAction.NotificationListenerSettings),
            SetupFeature.Camera to listOf(SetupAction.PostNotificationsPermission, SetupAction.CameraPermission),
            SetupFeature.Clipboard to emptyList(),
        )
        for ((feature, actions) in expected) {
            val state = SetupStateResolver.resolve(missing.copy(selection = SetupSelection(setOf(feature), true)))
            assertEquals(feature.name, actions, state.cards.map { it.action })
        }
    }

    @Test
    fun fullMacScreenAndAudioDoNotRequireBackupCapturePermissions() {
        val state = SetupStateResolver.resolve(readySnapshot.copy(
            selection = SetupSelection(setOf(SetupFeature.ScreenAndApps, SetupFeature.PhoneAudio), true),
            connectionPath = SetupConnectionPath.FullMac,
            postNotificationsGranted = false, cameraGranted = false,
            recordAudioGranted = false, accessibilityEnabled = false,
        ))
        assertTrue(state.cards.isEmpty())
        assertEquals(SetupStage.CheckOnMac, state.stage)
    }

    @Test
    fun permissionsAndPairingAreNeverProofThatSelectedFeaturesWork() {
        assertEquals(SetupStage.CheckOnMac, SetupStateResolver.resolve(readySnapshot).stage)
    }

    @Test
    fun settingsReturnAndPermissionRevocationOnlyChangeTheAffectedRequirement() {
        val selected = readySnapshot.copy(selection = SetupSelection(setOf(SetupFeature.Files, SetupFeature.Camera), true))
        assertTrue(SetupStateResolver.resolve(selected).cards.isEmpty())
        assertEquals(listOf(SetupAction.CameraPermission), SetupStateResolver.resolve(selected.copy(cameraGranted = false)).cards.map { it.action })
        assertTrue(SetupStateResolver.resolve(selected).cards.isEmpty())
        assertTrue(SetupStateResolver.resolve(selected.copy(safReadWriteGrantPersisted = false)).cards.isEmpty())
    }

    @Test
    fun savedChoiceRestoresWithoutGrantsAndChangesNeedConfirmation() {
        val selection = SetupSelection().selecting(SetupFeature.Files, true).selecting(SetupFeature.Camera, true).confirm()
        assertEquals(selection, SetupSelection.restore(selection.savedIDs, selection.confirmed))
        assertFalse(selection.selecting(SetupFeature.Camera, false).confirmed)
        assertFalse(SetupSelection.restore(null, true).confirmed)
        assertFalse(SetupSelection.restore(setOf("future"), true).confirmed)
        assertEquals(setOf(SetupFeature.Files), SetupSelection.restore(setOf("files", "future"), true).features)
        assertFalse(SetupSelection.restore(setOf("files", "future"), true).confirmed)
    }

    @Test
    fun losingDialerRoleKeepsTheSavedChoiceVisibleWithoutRequestingNewPermissions() {
        val snapshot = readySnapshot.copy(
            distribution = "direct", dialerRoleHeld = false, callRuntimePermissionsGranted = false,
            selection = SetupSelection(setOf(SetupFeature.Calls), true),
        )
        val state = SetupStateResolver.resolve(snapshot)
        assertEquals(setOf(SetupFeature.Calls), state.unavailableFeatures)
        assertTrue(state.runtimeQueue.isEmpty())
        assertTrue(SetupFeature.Calls in SetupStateResolver.availableFeatures(snapshot))
        assertFalse(SetupFeature.Calls in SetupStateResolver.availableFeatures(snapshot.copy(selection = SetupSelection())))
    }

    @Test
    fun legacyAndroidNeverRequestsNewerNetworkOrNotificationPermissions() {
        val state = SetupStateResolver.resolve(readySnapshot.copy(
            apiLevel = 31, localNetworkGranted = false, postNotificationsGranted = false,
            cameraGranted = false, selection = SetupSelection(setOf(SetupFeature.Camera), true),
        ))
        assertEquals(listOf(SetupAction.CameraPermission), state.runtimeQueue)
    }

    @Test
    fun commonConnectionRequirementsAreDeduplicatedAndRemainAfterSettingsReturn() {
        val snapshot = readySnapshot.copy(
            selection = SetupSelection(setOf(SetupFeature.Files, SetupFeature.Camera), true),
            paired = false, localNetworkGranted = false, cameraGranted = false,
        )
        assertEquals(listOf(SetupAction.LocalNetworkPermission, SetupAction.CameraPermission, SetupAction.PairMac),
            SetupStateResolver.resolve(snapshot).cards.map { it.action })
        val afterGrant = SetupStateResolver.resolve(snapshot.copy(cameraGranted = true, localNetworkGranted = true))
        assertEquals(listOf(SetupAction.PairMac), afterGrant.cards.map { it.action })
        assertEquals(SetupStage.PairMac, afterGrant.stage)
        assertEquals(SetupStage.CheckOnMac, SetupStateResolver.resolve(snapshot.copy(
            cameraGranted = true, localNetworkGranted = true, paired = true)).stage)
    }

    @Test
    fun removingTheLastChoiceCannotPersistACompletedSetup() {
        val empty = SetupSelection(setOf(SetupFeature.Files), true).selecting(SetupFeature.Files, false).confirm()
        assertFalse(empty.confirmed)
        val restored = SetupSelection.restore(empty.savedIDs, true)
        assertFalse(restored.confirmed)
        assertEquals(SetupStage.ChooseFeatures, SetupStateResolver.resolve(readySnapshot.copy(selection = restored)).stage)
    }

    private val readySnapshot = SetupSnapshot(
        apiLevel = 37,
        distribution = "play",
        paired = true,
        localNetworkGranted = true,
        postNotificationsGranted = true,
        cameraGranted = true,
        recordAudioGranted = true,
        accessibilityEnabled = true,
        notificationListenerEnabled = true,
        safReadWriteGrantPersisted = true,
        dialerRoleHeld = true,
        callRuntimePermissionsGranted = true,
        selection = SetupSelection(SetupFeature.entries.toSet(), true),
        connectionPath = SetupConnectionPath.PhoneScreenSharing,
    )
}
