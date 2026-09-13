package com.xopmc.galaxybridge.setup

enum class SetupFeature(val storageID: String) {
    ScreenAndApps("screen_apps"), PhoneAudio("phone_audio"), Clipboard("clipboard"),
    Notifications("notifications"), Files("files"), Camera("camera"), Calls("calls"),
}

data class SetupSelection(val features: Set<SetupFeature> = emptySet(), val confirmed: Boolean = false) {
    fun selecting(feature: SetupFeature, selected: Boolean) = copy(
        features = if (selected) features + feature else features - feature,
        confirmed = false,
    )
    fun confirm() = copy(confirmed = features.isNotEmpty())
    val savedIDs: Set<String> get() = features.mapTo(mutableSetOf()) { it.storageID }
    companion object {
        fun restore(ids: Set<String>?, confirmed: Boolean): SetupSelection {
            val features = SetupFeature.entries.filterTo(mutableSetOf()) { it.storageID in ids.orEmpty() }
            return SetupSelection(features, confirmed && features.isNotEmpty() && features.size == ids?.size)
        }
    }
}

enum class SetupConnectionPath { FullMac, PhoneScreenSharing }
// Permissions and a remembered pairing are prerequisites, not live feature proof.
enum class SetupStage { ChooseFeatures, Permissions, PairMac, CheckOnMac }

data class SetupSnapshot(
    val apiLevel: Int,
    val distribution: String,
    val paired: Boolean,
    val localNetworkGranted: Boolean,
    val postNotificationsGranted: Boolean,
    val cameraGranted: Boolean,
    val recordAudioGranted: Boolean,
    val accessibilityEnabled: Boolean,
    val notificationListenerEnabled: Boolean,
    val safReadWriteGrantPersisted: Boolean,
    val dialerRoleHeld: Boolean,
    val callRuntimePermissionsGranted: Boolean,
    val selection: SetupSelection = SetupSelection(),
    val connectionPath: SetupConnectionPath = SetupConnectionPath.FullMac,
)

data class SetupState(
    val cards: List<SetupCard>,
    val runtimeQueue: List<SetupAction>,
    val stage: SetupStage = SetupStage.ChooseFeatures,
    val unavailableFeatures: Set<SetupFeature> = emptySet(),
)

data class SetupCard(
    val action: SetupAction,
    val kind: SetupKind,
)

enum class SetupKind {
    RuntimePermission,
    SpecialAccess,
    Picker,
    Pairing,
}

enum class SetupAction {
    LocalNetworkPermission,
    PostNotificationsPermission,
    CameraPermission,
    RecordAudioPermission,
    AccessibilitySettings,
    NotificationListenerSettings,
    StorageAccessFolder,
    DialerRuntimePermissions,
    PairMac,
}

object SetupStateResolver {
    fun availableFeatures(snapshot: SetupSnapshot): List<SetupFeature> = SetupFeature.entries.filter {
        it != SetupFeature.Calls ||
            (DistributionFeatures.telephonyEnabled(snapshot.distribution) && snapshot.dialerRoleHeld) ||
            it in snapshot.selection.features
    }

    fun resolve(snapshot: SetupSnapshot): SetupState {
        val selected = snapshot.selection.features
        if (!snapshot.selection.confirmed || selected.isEmpty()) {
            return SetupState(emptyList(), emptyList(), SetupStage.ChooseFeatures)
        }
        val requirements = selected.flatMap { requirements(it, snapshot) }.toSet()
        val cards = SetupAction.entries.filter { it in requirements }.map {
            SetupCard(it, when (it) {
                SetupAction.AccessibilitySettings, SetupAction.NotificationListenerSettings -> SetupKind.SpecialAccess
                SetupAction.StorageAccessFolder -> SetupKind.Picker
                SetupAction.PairMac -> SetupKind.Pairing
                else -> SetupKind.RuntimePermission
            })
        }
        val unavailable = selected.filterTo(mutableSetOf()) {
            it == SetupFeature.Calls && (!DistributionFeatures.telephonyEnabled(snapshot.distribution) || !snapshot.dialerRoleHeld)
        }
        val stage = when {
            cards.any { it.action != SetupAction.PairMac } -> SetupStage.Permissions
            !snapshot.paired -> SetupStage.PairMac
            else -> SetupStage.CheckOnMac
        }
        return SetupState(cards, cards.filter { it.kind == SetupKind.RuntimePermission }.map { it.action }, stage, unavailable)
    }

    // This inventory does not launch requests. Only an explicit UI action may do so.
    fun requirements(feature: SetupFeature, snapshot: SetupSnapshot): Set<SetupAction> = buildSet {
        if (snapshot.apiLevel >= 37 && !snapshot.localNetworkGranted) add(SetupAction.LocalNetworkPermission)
        if (!snapshot.paired) add(SetupAction.PairMac)
        when (feature) {
            SetupFeature.Camera -> {
                if (snapshot.apiLevel >= 33 && !snapshot.postNotificationsGranted) add(SetupAction.PostNotificationsPermission)
                if (!snapshot.cameraGranted) add(SetupAction.CameraPermission)
            }
            SetupFeature.Notifications -> if (!snapshot.notificationListenerEnabled) add(SetupAction.NotificationListenerSettings)
            // Production transfers publish into Download/GalaxyBridge through MediaStore.
            SetupFeature.Files -> Unit
            SetupFeature.ScreenAndApps -> if (snapshot.connectionPath == SetupConnectionPath.PhoneScreenSharing && !snapshot.accessibilityEnabled) {
                add(SetupAction.AccessibilitySettings)
            }
            SetupFeature.PhoneAudio -> if (snapshot.connectionPath == SetupConnectionPath.PhoneScreenSharing && !snapshot.recordAudioGranted) {
                add(SetupAction.RecordAudioPermission)
            }
            SetupFeature.Calls -> if (DistributionFeatures.telephonyEnabled(snapshot.distribution) && snapshot.dialerRoleHeld && !snapshot.callRuntimePermissionsGranted) {
                add(SetupAction.DialerRuntimePermissions)
            }
            SetupFeature.Clipboard -> Unit
        }
    }
}

object DistributionFeatures {
    fun telephonyEnabled(distribution: String): Boolean = distribution == "internal" || distribution == "direct"
}

data class RuntimePermissionRequestGate(val inFlight: SetupAction? = null) {
    fun begin(action: SetupAction): RuntimePermissionRequestGate {
        require(inFlight == null) { "a runtime permission request is already in flight" }
        return copy(inFlight = action)
    }
    // Completing a result never schedules another request, even after a denial.
    fun complete(): RuntimePermissionRequestGate = copy(inFlight = null)
}

object SafInitialLocation {
    const val documentsUri =
        "content://com.android.externalstorage.documents/document/primary%3ADocuments"
}
