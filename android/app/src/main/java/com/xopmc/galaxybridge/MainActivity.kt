package com.xopmc.galaxybridge

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.NotificationManager
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Base64
import android.util.Size
import android.view.accessibility.AccessibilityManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.dimensionResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.net.toUri
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.xopmc.galaxybridge.core.ADBBindingTranscript
import com.xopmc.galaxybridge.core.PairingUriCodec
import com.xopmc.galaxybridge.qr.LocalQrCodeDecoder
import com.xopmc.galaxybridge.qr.QrScanGate
import com.xopmc.galaxybridge.security.DeviceIdentityStore
import com.xopmc.galaxybridge.service.CameraCaptureService
import com.xopmc.galaxybridge.service.GalaxyAccessibilityService
import com.xopmc.galaxybridge.service.GalaxyBridgeForegroundService
import com.xopmc.galaxybridge.service.ForegroundClipboardMonitor
import com.xopmc.galaxybridge.service.GalaxyNotificationListenerService
import com.xopmc.galaxybridge.service.MediaProjectionCaptureService
import com.xopmc.galaxybridge.setup.SetupAction
import com.xopmc.galaxybridge.setup.SetupCard
import com.xopmc.galaxybridge.setup.SetupKind
import com.xopmc.galaxybridge.setup.RuntimePermissionRequestGate
import com.xopmc.galaxybridge.setup.SetupFeature
import com.xopmc.galaxybridge.setup.SetupSelection
import com.xopmc.galaxybridge.setup.SetupState
import com.xopmc.galaxybridge.setup.SetupConnectionPath
import com.xopmc.galaxybridge.setup.SetupSnapshot
import com.xopmc.galaxybridge.setup.SetupStateResolver
import com.xopmc.galaxybridge.setup.DistributionFeatures
import com.xopmc.galaxybridge.setup.SafInitialLocation
import com.xopmc.galaxybridge.storage.EncryptedContentCache
import com.xopmc.galaxybridge.transport.AdbBindingResponseBus
import com.xopmc.galaxybridge.transport.PairingStateBus
import com.xopmc.galaxybridge.transport.SignedAdbBindingResponse
import java.util.concurrent.Executors

class MainActivity : ComponentActivity() {
    private var refreshToken by mutableIntStateOf(0)
    private var runtimePermissionGate = RuntimePermissionRequestGate()
    private var setupActionError by mutableStateOf<String?>(null)
    private lateinit var foregroundClipboardMonitor: ForegroundClipboardMonitor
    private val singlePermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) startBridgeServiceIfAllowed()
        completeRuntimePermission()
        refreshToken++
    }
    private val callPermissionsLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        completeRuntimePermission()
        refreshToken++
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        foregroundClipboardMonitor = ForegroundClipboardMonitor(this)
        runtimePermissionGate = RuntimePermissionRequestGate(
            inFlight = savedInstanceState
                ?.getString(STATE_RUNTIME_PERMISSION_IN_FLIGHT)
                ?.let { name -> SetupAction.entries.firstOrNull { it.name == name } },
        )
        // Screen mirroring in the normal USB/Wireless ADB product path is
        // launched by the Mac through scrcpy. Retire a projection left by an
        // older build so opening Galaxy Bridge cannot keep Android's capture
        // privacy indicator active or suppress notification contents.
        stopService(Intent(this, MediaProjectionCaptureService::class.java))
        startBridgeServiceIfAllowed()
        setContent {
            GalaxyBridgeTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    GalaxyBridgeHome(refreshToken)
                }
            }
        }
        handlePairingIntent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        runtimePermissionGate.inFlight?.let {
            outState.putString(STATE_RUNTIME_PERMISSION_IN_FLIGHT, it.name)
        }
        super.onSaveInstanceState(outState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handlePairingIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // Settings grants/revocations are read again; returning never opens a prompt.
        startBridgeServiceIfAllowed()
        refreshToken++
    }

    override fun onStart() {
        super.onStart()
        foregroundClipboardMonitor.onStarted()
    }

    override fun onStop() {
        foregroundClipboardMonitor.onStopped()
        super.onStop()
    }

    override fun onDestroy() {
        foregroundClipboardMonitor.close()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        foregroundClipboardMonitor.onWindowFocusChanged(hasFocus)
        if (hasFocus) refreshToken++
    }

    private fun handlePairingIntent(intent: Intent) {
        handlePairingUri(intent.data ?: return)
    }

    private fun handlePairingUri(uri: Uri) {
        if (uri.scheme != "galaxybridge") return
        if (uri.host == "pair") {
            storePendingPairing(uri.toString())
        } else if (uri.host == "bind") {
            handleAdbBindingIntent(uri)
        }
    }

    private fun storePendingPairing(uri: String) {
        getSharedPreferences(PREFERENCES, MODE_PRIVATE).edit {
            putString("pending_pairing", uri)
        }
        startBridgeServiceIfAllowed()
        refreshToken++
    }

    private fun handleAdbBindingIntent(uri: Uri) {
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        val pairedHostId = preferences.getString("paired_host_id", null) ?: return
        val hostId = uri.getQueryParameter("host") ?: return
        val expectedDeviceId = uri.getQueryParameter("device") ?: return
        val adbSerial = uri.getQueryParameter("serial") ?: return
        val nonce = uri.getQueryParameter("nonce")?.let { encoded ->
            runCatching {
                Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            }.getOrNull()
        } ?: return
        val localDeviceId = preferences.getString("device_id", null) ?: return
        if (hostId != pairedHostId || expectedDeviceId != localDeviceId ||
            adbSerial.isBlank() || adbSerial.length > 128 || nonce.size != 32
        ) return

        val identity = DeviceIdentityStore()
        val publicKey = identity.publicKeyX963()
        val transcript = ADBBindingTranscript.make(hostId, adbSerial, nonce, publicKey)
        AdbBindingResponseBus.publish(
            SignedAdbBindingResponse(
                adbSerial = adbSerial,
                nonce = nonce,
                identityPublicKey = publicKey,
                signature = identity.signNonce(transcript),
            ),
        )
    }

    @Composable
    private fun GalaxyBridgeHome(token: Int) {
        var screen by remember { mutableStateOf(HomeScreen.Home) }
        var showAccessibilityDisclosure by remember { mutableStateOf(false) }
        var showRevokeConfirmation by remember { mutableStateOf(false) }
        var qrStatus by remember { mutableStateOf<String?>(null) }

        LaunchedEffect(Unit) {
            PairingStateBus.revision.collect { refreshToken++ }
        }

        val settingsLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { refreshToken++ }
        val folderLauncher = rememberLauncherForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            val uri = result.data?.data
            val grantFlags = result.data?.flags?.and(SAF_RW_FLAGS) ?: 0
            if (result.resultCode == Activity.RESULT_OK && uri != null && grantFlags == SAF_RW_FLAGS) {
                runCatching { contentResolver.takePersistableUriPermission(uri, SAF_RW_FLAGS) }
                    .onSuccess {
                        getSharedPreferences(PREFERENCES, MODE_PRIVATE).edit {
                            putString("saf_tree", uri.toString())
                        }
                    }
            }
            refreshToken++
        }

        fun requestRuntime(action: SetupAction) {
            requestRuntimePermission(action)
        }

        fun launchFolderPicker() {
            fun pickerIntent(includeInitialLocation: Boolean) =
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    .addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    .addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    .also { intent ->
                        if (includeInitialLocation) {
                            intent.putExtra(
                                DocumentsContract.EXTRA_INITIAL_URI,
                                SafInitialLocation.documentsUri.toUri(),
                            )
                        }
                    }

            runCatching { folderLauncher.launch(pickerIntent(includeInitialLocation = true)) }
                .onFailure { folderLauncher.launch(pickerIntent(includeInitialLocation = false)) }
        }

        fun openSettings(action: SetupAction) {
            setupActionError = null
            runCatching {
                when (action) {
                    SetupAction.AccessibilitySettings -> {
                        if (BuildConfig.DISTRIBUTION == "play") {
                            showAccessibilityDisclosure = true
                        } else {
                            runCatching { settingsLauncher.launch(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
                                .onFailure { setupActionError = getString(R.string.setup_action_unavailable) }
                        }
                    }
                    SetupAction.NotificationListenerSettings ->
                        settingsLauncher.launch(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    SetupAction.StorageAccessFolder -> launchFolderPicker()
                    SetupAction.PairMac -> {
                        qrStatus = null
                        screen = HomeScreen.QrScanner
                    }
                    else -> requestRuntime(action)
                }
            }.onFailure { setupActionError = getString(R.string.setup_action_unavailable) }
        }

        val snapshot = remember(token) { setupSnapshot() }
        val setupState = SetupStateResolver.resolve(snapshot)

        BackHandler(enabled = screen != HomeScreen.Home) {
            screen = HomeScreen.Home
        }

        when (screen) {
            HomeScreen.Home -> HomeContent(
                snapshot = snapshot,
                setupState = setupState,
                actionError = setupActionError,
                onFeatureChoice = { feature, selected -> saveSetupSelection(setupSelection().selecting(feature, selected)) },
                onConfirmChoices = { saveSetupSelection(setupSelection().confirm()) },
                onEditChoices = { saveSetupSelection(setupSelection().copy(confirmed = false)) },
                onSetupAction = ::openSettings,
                permissionNeedsSettings = ::permissionNeedsSettings,
                onScanPairing = {
                    qrStatus = null
                    screen = HomeScreen.QrScanner
                },
                onRevoke = { showRevokeConfirmation = true },
                onOpenAbout = { screen = HomeScreen.About },
            )
            HomeScreen.QrScanner -> QrScannerScreen(
                cameraGranted = hasCameraPermission(),
                status = qrStatus ?: setupActionError,
                cameraRequestOpensSettings = permissionNeedsSettings(SetupAction.CameraPermission),
                onRequestCamera = { requestRuntimePermission(SetupAction.CameraPermission, forQrScanner = true) },
                onClose = { screen = HomeScreen.Home },
                onQrCode = { value ->
                    if (isValidPairingUri(value)) {
                        storePendingPairing(value)
                        qrStatus = null
                        screen = HomeScreen.Home
                        true
                    } else {
                        qrStatus = getString(R.string.qr_invalid)
                        false
                    }
                },
            )
            HomeScreen.About -> AboutScreen(
                onClose = { screen = HomeScreen.Home },
                onOpenGitHub = {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(AboutContent.githubURL)))
                },
            )
        }

        if (showAccessibilityDisclosure) {
            AlertDialog(
                onDismissRequest = { showAccessibilityDisclosure = false },
                title = { Text(stringResource(R.string.accessibility_disclosure_title)) },
                text = { Text(stringResource(R.string.accessibility_disclosure_body)) },
                confirmButton = {
                    Button(
                        onClick = {
                            showAccessibilityDisclosure = false
                            runCatching { settingsLauncher.launch(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
                                .onFailure { setupActionError = getString(R.string.setup_action_unavailable) }
                        },
                    ) { Text(stringResource(R.string.action_continue)) }
                },
                dismissButton = {
                    TextButton(onClick = { showAccessibilityDisclosure = false }) {
                        Text(stringResource(R.string.action_cancel))
                    }
                },
            )
        }
        if (showRevokeConfirmation) {
            AlertDialog(
                onDismissRequest = { showRevokeConfirmation = false },
                title = { Text(stringResource(R.string.revoke_pairing_title)) },
                text = { Text(stringResource(R.string.revoke_pairing_body)) },
                confirmButton = {
                    Button(
                        onClick = {
                            showRevokeConfirmation = false
                            revokePairing()
                        },
                    ) { Text(stringResource(R.string.action_revoke)) }
                },
                dismissButton = {
                    TextButton(onClick = { showRevokeConfirmation = false }) {
                        Text(stringResource(R.string.action_cancel))
                    }
                },
            )
        }
    }

    private fun setupSnapshot(): SetupSnapshot {
        val roleManager = getSystemService(RoleManager::class.java)
        val telephonyEnabled = DistributionFeatures.telephonyEnabled(BuildConfig.DISTRIBUTION)
        val dialerRoleHeld = telephonyEnabled && roleManager.isRoleHeld(RoleManager.ROLE_DIALER)
        return SetupSnapshot(
            apiLevel = Build.VERSION.SDK_INT,
            distribution = BuildConfig.DISTRIBUTION,
            paired = getSharedPreferences(PREFERENCES, MODE_PRIVATE).getString("paired_host_id", null) != null,
            localNetworkGranted = hasLocalNetworkAccess(),
            postNotificationsGranted = hasPostNotificationsPermission(),
            cameraGranted = hasCameraPermission(),
            recordAudioGranted = hasRecordAudioPermission(),
            accessibilityEnabled = isAccessibilityEnabled(),
            notificationListenerEnabled = getSystemService(NotificationManager::class.java)
                .isNotificationListenerAccessGranted(ComponentName(this, GalaxyNotificationListenerService::class.java)),
            safReadWriteGrantPersisted = hasPersistedSafReadWriteGrant(),
            dialerRoleHeld = dialerRoleHeld,
            callRuntimePermissionsGranted = telephonyEnabled && CALL_PERMISSIONS.all {
                ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
            },
            selection = setupSelection(),
            // This chooses the normal product setup path, not proof of a live link.
            connectionPath = SetupConnectionPath.FullMac,
        )
    }

    private fun revokePairing() {
        stopService(Intent(this, MediaProjectionCaptureService::class.java))
        stopService(Intent(this, CameraCaptureService::class.java))
        EncryptedContentCache(this).use { it.revokeAll() }
        getSharedPreferences(PREFERENCES, MODE_PRIVATE).edit {
            remove("pending_pairing")
            remove("paired_mac_key")
            remove("paired_host_id")
            remove("paired_at")
        }
        AdbBindingResponseBus.clear()
        startBridgeServiceIfAllowed(GalaxyBridgeForegroundService.ACTION_TRUST_REVOKED)
        refreshToken++
    }

    private fun hasLocalNetworkAccess(): Boolean =
        Build.VERSION.SDK_INT < 37 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED

    private fun hasPostNotificationsPermission(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun hasRecordAudioPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun hasPersistedSafReadWriteGrant(): Boolean {
        val storedUri = getSharedPreferences(PREFERENCES, MODE_PRIVATE).getString("saf_tree", null) ?: return false
        return contentResolver.persistedUriPermissions.any {
            it.uri.toString() == storedUri && it.isReadPermission && it.isWritePermission
        }
    }

    private fun setupSelection(): SetupSelection {
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        return SetupSelection.restore(
            preferences.getStringSet(SETUP_FEATURES, null),
            preferences.getBoolean(SETUP_CHOICES_CONFIRMED, false),
        )
    }

    private fun saveSetupSelection(selection: SetupSelection) {
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        val saved = preferences.edit()
            .putStringSet(SETUP_FEATURES, selection.savedIDs)
            .putBoolean(SETUP_CHOICES_CONFIRMED, selection.confirmed)
            .commit()
        setupActionError = if (saved) null else getString(R.string.setup_save_failed)
        if (!saved) preferences.edit { putBoolean(SETUP_CHOICES_CONFIRMED, false) }
        refreshToken++
    }

    private fun permissionsFor(action: SetupAction): List<String> = when (action) {
        SetupAction.LocalNetworkPermission -> if (Build.VERSION.SDK_INT >= 37) listOf(Manifest.permission.ACCESS_LOCAL_NETWORK) else emptyList()
        SetupAction.PostNotificationsPermission -> if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()
        SetupAction.CameraPermission -> listOf(Manifest.permission.CAMERA)
        SetupAction.RecordAudioPermission -> listOf(Manifest.permission.RECORD_AUDIO)
        SetupAction.DialerRuntimePermissions -> CALL_PERMISSIONS.toList()
        else -> emptyList()
    }

    private fun permissionNeedsSettings(action: SetupAction): Boolean {
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        val previouslyRequested = preferences.getBoolean("setup_requested_${action.name}", false) ||
            preferences.getBoolean("auto_requested_${action.name}", false)
        return previouslyRequested && permissionsFor(action).any {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED &&
                !shouldShowRequestPermissionRationale(it)
        }
    }

    private fun requestRuntimePermission(action: SetupAction, forQrScanner: Boolean = false) {
        if (runtimePermissionGate.inFlight != null) return
        val selectedRequest = action in SetupStateResolver.resolve(setupSnapshot()).runtimeQueue
        val scannerRequest = forQrScanner && action == SetupAction.CameraPermission && !hasCameraPermission()
        if (!selectedRequest && !scannerRequest) return
        setupActionError = null
        if (permissionNeedsSettings(action)) {
            runCatching {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
            }.onFailure { setupActionError = getString(R.string.setup_action_unavailable) }
            return
        }
        runtimePermissionGate = runtimePermissionGate.begin(action)
        val launched = runCatching { launchRuntimePermission(action) }
            .onFailure { setupActionError = getString(R.string.setup_action_unavailable) }
            .getOrDefault(false)
        if (launched) {
            getSharedPreferences(PREFERENCES, MODE_PRIVATE).edit {
                putBoolean("setup_requested_${action.name}", true)
            }
        } else {
            runtimePermissionGate = runtimePermissionGate.complete()
        }
    }

    private fun completeRuntimePermission() {
        runtimePermissionGate = runtimePermissionGate.complete()
        // A result, denial, settings return, or relaunch never starts another dialog.
    }

    private fun launchRuntimePermission(action: SetupAction): Boolean = when (action) {
        SetupAction.LocalNetworkPermission -> if (Build.VERSION.SDK_INT >= 37) {
            singlePermissionLauncher.launch(Manifest.permission.ACCESS_LOCAL_NETWORK)
            true
        } else {
            false
        }
        SetupAction.PostNotificationsPermission -> if (Build.VERSION.SDK_INT >= 33) {
            singlePermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            true
        } else {
            false
        }
        SetupAction.CameraPermission -> {
            singlePermissionLauncher.launch(Manifest.permission.CAMERA)
            true
        }
        SetupAction.RecordAudioPermission -> {
            singlePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
            true
        }
        SetupAction.DialerRuntimePermissions -> {
            callPermissionsLauncher.launch(CALL_PERMISSIONS)
            true
        }
        else -> false
    }

    private fun startBridgeServiceIfAllowed(action: String? = null) {
        if (!hasLocalNetworkAccess()) return
        ContextCompat.startForegroundService(
            this,
            Intent(this, GalaxyBridgeForegroundService::class.java).also { it.action = action },
        )
    }

    private fun isAccessibilityEnabled(): Boolean =
        getSystemService(AccessibilityManager::class.java)
            .getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            .any { it.resolveInfo.serviceInfo.packageName == packageName && it.resolveInfo.serviceInfo.name == GalaxyAccessibilityService::class.java.name }

    private fun isValidPairingUri(value: String): Boolean =
        runCatching {
            PairingUriCodec.decode(value, System.currentTimeMillis() / 1_000)
            true
        }.getOrDefault(false)

    private enum class HomeScreen {
        Home,
        QrScanner,
        About,
    }

    companion object {
        private const val PREFERENCES = "galaxybridge"
        private const val SETUP_FEATURES = "setup_selected_features_v1"
        private const val SETUP_CHOICES_CONFIRMED = "setup_choices_confirmed_v1"
        private const val STATE_RUNTIME_PERMISSION_IN_FLIGHT = "runtime_permission_in_flight"
        private const val SAF_RW_FLAGS = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        private val CALL_PERMISSIONS = arrayOf(
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.READ_CALL_LOG,
            Manifest.permission.ANSWER_PHONE_CALLS,
        )
    }
}

@Composable
internal fun GalaxyBridgeTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val colors = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    MaterialTheme(
        colorScheme = colors,
        content = content,
    )
}

@Composable
private fun HomeContent(
    snapshot: SetupSnapshot,
    setupState: SetupState,
    actionError: String?,
    onFeatureChoice: (SetupFeature, Boolean) -> Unit,
    onConfirmChoices: () -> Unit,
    onEditChoices: () -> Unit,
    onSetupAction: (SetupAction) -> Unit,
    permissionNeedsSettings: (SetupAction) -> Boolean,
    onScanPairing: () -> Unit,
    onRevoke: () -> Unit,
    onOpenAbout: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceContainerLowest)
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(
                start = dimensionResource(R.dimen.one_ui_content_horizontal),
                top = dimensionResource(R.dimen.one_ui_content_top),
                end = dimensionResource(R.dimen.one_ui_content_horizontal),
                bottom = dimensionResource(R.dimen.one_ui_content_bottom),
            ),
        verticalArrangement = Arrangement.spacedBy(dimensionResource(R.dimen.one_ui_section_spacing)),
    ) {
        Header()
        FeatureChoicesPanel(snapshot, onFeatureChoice, onConfirmChoices, onEditChoices)
        if (actionError != null) {
            Text(actionError, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }
        if (snapshot.selection.confirmed) {
            IdentityPanel(
                paired = snapshot.paired,
                onScanPairing = onScanPairing,
                onRevoke = onRevoke,
            )
            MissingSetupPanel(
                setupCards = setupState.cards.filter { it.action != SetupAction.PairMac },
                onSetupAction = onSetupAction,
                permissionNeedsSettings = permissionNeedsSettings,
            )
            MacVerificationPanel(snapshot, setupState)
            if (SetupFeature.Files in snapshot.selection.features && snapshot.paired) {
                OutgoingFilesPanel()
            }
            if (SetupFeature.Notifications in snapshot.selection.features) {
                SmsNotificationOnlyPanel(notificationListenerEnabled = snapshot.notificationListenerEnabled)
            }
        }
        OneUiOutlinedButton(onClick = onOpenAbout) {
            Text(stringResource(R.string.about_entry))
        }
    }
}

@Composable
private fun AboutScreen(
    onClose: () -> Unit,
    onOpenGitHub: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceContainerLowest)
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(
                start = dimensionResource(R.dimen.one_ui_content_horizontal),
                top = 8.dp,
                end = dimensionResource(R.dimen.one_ui_content_horizontal),
                bottom = dimensionResource(R.dimen.one_ui_content_bottom),
            ),
        verticalArrangement = Arrangement.spacedBy(dimensionResource(R.dimen.one_ui_section_spacing)),
    ) {
        TextButton(onClick = onClose) {
            Text(stringResource(R.string.action_back))
        }
        Image(
            painter = painterResource(R.drawable.ic_galaxy_bridge_brand),
            contentDescription = stringResource(R.string.about_icon_content_description),
            modifier = Modifier
                .size(112.dp)
                .align(Alignment.CenterHorizontally),
        )
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = stringResource(R.string.about_title),
                style = MaterialTheme.typography.displaySmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = stringResource(R.string.home_subtitle),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        LayeredCard {
            Text(
                text = stringResource(R.string.about_author_label),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = AboutContent.author,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(14.dp))
            OneUiPrimaryButton(onClick = onOpenGitHub) {
                Text(stringResource(R.string.about_github_action))
            }
        }
    }
}

@Composable
private fun Header() {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = stringResource(R.string.home_title),
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = stringResource(R.string.home_subtitle),
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun IdentityPanel(
    paired: Boolean,
    onScanPairing: () -> Unit,
    onRevoke: () -> Unit,
) {
    LayeredCard {
        Text(
            stringResource(R.string.identity_title),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
            StatusPill(if (paired) R.string.status_paired else R.string.status_not_paired, paired)
        }
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(if (paired) R.string.pairing_paired_hint else R.string.pairing_scan_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OneUiPrimaryButton(onClick = onScanPairing) {
                Text(stringResource(if (paired) R.string.action_scan_another else R.string.action_scan_qr))
            }
            if (paired) {
                OneUiOutlinedButton(onClick = onRevoke) {
                    Text(stringResource(R.string.action_revoke))
                }
            }
        }
    }
}

@Composable
private fun FeatureChoicesPanel(
    snapshot: SetupSnapshot,
    onChoice: (SetupFeature, Boolean) -> Unit,
    onConfirm: () -> Unit,
    onEdit: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.setup_features_title), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Text(stringResource(R.string.setup_features_body), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (snapshot.selection.confirmed) {
            LayeredCard {
                SetupFeature.entries.filter { it in snapshot.selection.features }.forEach {
                    Text(featureTitle(it), style = MaterialTheme.typography.bodyLarge)
                }
                Spacer(Modifier.height(12.dp))
                OneUiOutlinedButton(onClick = onEdit) { Text(stringResource(R.string.setup_edit_choices)) }
            }
        } else {
            SetupStateResolver.availableFeatures(snapshot).forEach { feature ->
                val selected = feature in snapshot.selection.features
                LayeredCard {
                    Row(
                        modifier = Modifier.fillMaxWidth().toggleable(
                            value = selected,
                            role = Role.Checkbox,
                            onValueChange = { onChoice(feature, it) },
                        ).padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(featureTitle(feature), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            Text(featureDescription(feature), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Checkbox(checked = selected, onCheckedChange = null)
                    }
                }
            }
            if (snapshot.selection.features.isEmpty()) {
                Text(stringResource(R.string.setup_choose_one), style = MaterialTheme.typography.bodyMedium)
            }
            OneUiPrimaryButton(onClick = onConfirm, enabled = snapshot.selection.features.isNotEmpty()) {
                Text(stringResource(R.string.setup_save_choices))
            }
        }
    }
}

@Composable
private fun MacVerificationPanel(snapshot: SetupSnapshot, state: SetupState) {
    LayeredCard {
        Text(stringResource(R.string.setup_waiting_title), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(stringResource(R.string.setup_waiting_body), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(10.dp))
        SetupFeature.entries.filter { it in snapshot.selection.features }.forEach { feature ->
            val missing = SetupStateResolver.requirements(feature, snapshot)
            val label = when {
                feature in state.unavailableFeatures -> R.string.setup_feature_unavailable
                missing.any { it != SetupAction.PairMac } -> R.string.status_action_required
                !snapshot.paired -> R.string.status_not_paired
                else -> R.string.setup_test_pending
            }
            Column(modifier = Modifier.padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(featureTitle(feature), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                Text(stringResource(label), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun featureTitle(feature: SetupFeature): String = stringResource(when (feature) {
    SetupFeature.ScreenAndApps -> R.string.setup_screen_feature_title
    SetupFeature.PhoneAudio -> R.string.microphone_title
    SetupFeature.Clipboard -> R.string.setup_clipboard_feature_title
    SetupFeature.Notifications -> R.string.notifications_title
    SetupFeature.Files -> R.string.files_title
    SetupFeature.Camera -> R.string.camera_title
    SetupFeature.Calls -> R.string.calls_permissions_title
})

@Composable
private fun featureDescription(feature: SetupFeature): String = stringResource(when (feature) {
    SetupFeature.ScreenAndApps -> R.string.setup_screen_feature_body
    SetupFeature.PhoneAudio -> R.string.setup_audio_feature_body
    SetupFeature.Clipboard -> R.string.setup_clipboard_feature_body
    SetupFeature.Notifications -> R.string.notifications_description
    SetupFeature.Files -> R.string.files_description
    SetupFeature.Camera -> R.string.camera_description
    SetupFeature.Calls -> R.string.calls_permissions_description
})

@Composable
private fun MissingSetupPanel(
    setupCards: List<SetupCard>,
    onSetupAction: (SetupAction) -> Unit,
    permissionNeedsSettings: (SetupAction) -> Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            stringResource(R.string.setup_permission_section_title),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        if (setupCards.isEmpty()) {
            LayeredCard {
                Text(
                    stringResource(R.string.setup_permissions_allowed),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            setupCards.forEach { card ->
                SetupActionCard(card = card, opensAppSettings = permissionNeedsSettings(card.action), onAction = { onSetupAction(card.action) })
            }
        }
    }
}

@Composable
private fun SetupActionCard(card: SetupCard, opensAppSettings: Boolean, onAction: () -> Unit) {
    LayeredCard {
        Text(
            actionTitle(card.action),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            actionDescription(card.action),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(10.dp))
        StatusPill(R.string.status_action_required, false)
        Spacer(Modifier.height(12.dp))
        OneUiPrimaryButton(onClick = onAction) {
            Text(if (opensAppSettings) stringResource(R.string.action_open_settings) else actionButtonLabel(card))
        }
    }
}

@Composable
private fun SmsNotificationOnlyPanel(notificationListenerEnabled: Boolean) {
    LayeredCard {
        Text(
            stringResource(R.string.sms_notification_only_title),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            stringResource(R.string.sms_notification_only_description),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(10.dp))
        StatusPill(
            if (notificationListenerEnabled) R.string.setup_permission_allowed else R.string.status_action_required,
            notificationListenerEnabled,
        )
    }
}

@Composable
private fun LayeredCard(content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(dimensionResource(R.dimen.one_ui_card_radius)),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(
            modifier = Modifier.padding(dimensionResource(R.dimen.one_ui_card_padding)),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            content = content,
        )
    }
}

@Composable
private fun OneUiPrimaryButton(
    onClick: () -> Unit,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = dimensionResource(R.dimen.one_ui_button_height)),
        shape = RoundedCornerShape(dimensionResource(R.dimen.one_ui_button_radius)),
        contentPadding = PaddingValues(horizontal = 24.dp, vertical = 14.dp),
    ) {
        ProvideTextStyle(MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold)) {
            content()
        }
    }
}

@Composable
private fun OneUiOutlinedButton(
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = dimensionResource(R.dimen.one_ui_button_height)),
        shape = RoundedCornerShape(dimensionResource(R.dimen.one_ui_button_radius)),
        contentPadding = PaddingValues(horizontal = 24.dp, vertical = 14.dp),
    ) {
        ProvideTextStyle(MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold)) {
            content()
        }
    }
}

@Composable
private fun StatusPill(label: Int, positive: Boolean) {
    val background = if (positive) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        MaterialTheme.colorScheme.errorContainer
    }
    val foreground = if (positive) {
        MaterialTheme.colorScheme.onPrimaryContainer
    } else {
        MaterialTheme.colorScheme.onErrorContainer
    }
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = background,
        contentColor = foreground,
    ) {
        Text(
            text = stringResource(label),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@Composable
private fun actionTitle(action: SetupAction): String = stringResource(
    when (action) {
        SetupAction.LocalNetworkPermission -> R.string.local_network_title
        SetupAction.PostNotificationsPermission -> R.string.post_notifications_title
        SetupAction.CameraPermission -> R.string.camera_title
        SetupAction.RecordAudioPermission -> R.string.microphone_title
        SetupAction.AccessibilitySettings -> R.string.input_title
        SetupAction.NotificationListenerSettings -> R.string.notifications_title
        SetupAction.StorageAccessFolder -> R.string.files_title
        SetupAction.DialerRuntimePermissions -> R.string.calls_permissions_title
        SetupAction.PairMac -> R.string.identity_title
    },
)

@Composable
private fun actionDescription(action: SetupAction): String = stringResource(
    when (action) {
        SetupAction.LocalNetworkPermission -> R.string.local_network_description
        SetupAction.PostNotificationsPermission -> R.string.setup_camera_notifications_description
        SetupAction.CameraPermission -> R.string.camera_description
        SetupAction.RecordAudioPermission -> R.string.microphone_description
        SetupAction.AccessibilitySettings -> R.string.input_description
        SetupAction.NotificationListenerSettings -> R.string.notifications_description
        SetupAction.StorageAccessFolder -> R.string.files_description
        SetupAction.DialerRuntimePermissions -> R.string.calls_permissions_description
        SetupAction.PairMac -> R.string.pairing_scan_hint
    },
)

@Composable
private fun actionButtonLabel(card: SetupCard): String = stringResource(
    when (card.kind) {
        SetupKind.RuntimePermission -> R.string.action_allow
        SetupKind.SpecialAccess -> R.string.action_open_settings
        SetupKind.Picker -> R.string.action_choose
        SetupKind.Pairing -> R.string.action_scan_qr
    },
)

@Composable
private fun QrScannerScreen(
    cameraGranted: Boolean,
    cameraRequestOpensSettings: Boolean,
    status: String?,
    onRequestCamera: () -> Unit,
    onClose: () -> Unit,
    onQrCode: (String) -> Boolean,
) {
    LaunchedEffect(cameraGranted) {
        if (!cameraGranted) onRequestCamera()
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .safeDrawingPadding()
            .padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text(
                stringResource(R.string.qr_scanner_title),
                style = MaterialTheme.typography.headlineSmall,
                color = Color.White,
            )
            TextButton(onClick = onClose, colors = ButtonDefaults.textButtonColors(contentColor = Color.White)) {
                Text(stringResource(R.string.action_close))
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .clip(RoundedCornerShape(32.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            if (cameraGranted) {
                CameraPreviewScanner(onQrCode = onQrCode)
            } else {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        stringResource(R.string.qr_camera_required),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    Button(onClick = onRequestCamera) {
                        Text(stringResource(if (cameraRequestOpensSettings) R.string.action_open_settings else R.string.action_allow))
                    }
                }
            }
        }
        Text(
            status ?: stringResource(R.string.qr_scanner_hint),
            color = if (status == null) Color.White.copy(alpha = 0.82f) else MaterialTheme.colorScheme.errorContainer,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun CameraPreviewScanner(onQrCode: (String) -> Boolean) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewContentDescription = stringResource(R.string.qr_preview_content_description)
    val previewView = remember(context, previewContentDescription) {
        PreviewView(context).apply {
            contentDescription = previewContentDescription
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }
    val scanGate = remember { QrScanGate() }
    AndroidView(
        factory = { previewView },
        modifier = Modifier.fillMaxSize(),
    )
    DisposableEffect(previewView, lifecycleOwner) {
        val analyzerExecutor = Executors.newSingleThreadExecutor()
        val providerFuture = ProcessCameraProvider.getInstance(context)
        val listener = Runnable {
            val provider = providerFuture.get()
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                Size(1280, 720),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                            ),
                        )
                        .build(),
                )
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { imageAnalysis ->
                    imageAnalysis.setAnalyzer(analyzerExecutor) { imageProxy ->
                        if (!scanGate.beginFrame()) {
                            imageProxy.close()
                            return@setAnalyzer
                        }
                        val raw = runCatching { LocalQrCodeDecoder.decode(imageProxy) }
                            .getOrNull()
                            ?.takeIf { it.startsWith("galaxybridge://pair") }
                        imageProxy.close()
                        if (raw == null) {
                            scanGate.completeFrame(accepted = false)
                        } else {
                            ContextCompat.getMainExecutor(context).execute {
                                val accepted = runCatching { onQrCode(raw) }.getOrDefault(false)
                                scanGate.completeFrame(accepted)
                            }
                        }
                    }
                }
            provider.unbindAll()
            provider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview,
                analysis,
            )
        }
        providerFuture.addListener(listener, ContextCompat.getMainExecutor(context))
        onDispose {
            runCatching { if (providerFuture.isDone) providerFuture.get().unbindAll() }
            analyzerExecutor.shutdown()
        }
    }
}
