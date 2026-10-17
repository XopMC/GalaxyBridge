package com.xopmc.galaxybridge.transport

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.xopmc.galaxybridge.protocol.v1.Capability
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.core.CompanionScreenPrivacyPolicy
import com.xopmc.galaxybridge.protocol.v1.CapabilityUpdate
import com.xopmc.galaxybridge.protocol.v1.TransportKind
import com.xopmc.galaxybridge.service.EncodedVideoBus
import com.xopmc.galaxybridge.service.EncodedAudioBus
import com.xopmc.galaxybridge.service.GalaxyAccessibilityService
import com.xopmc.galaxybridge.service.GalaxyNotificationListenerService
import com.xopmc.galaxybridge.service.TelephonyBridge
import com.xopmc.galaxybridge.setup.DistributionFeatures

internal object CompanionCapabilityResolver {
    fun resolve(context: Context): CapabilityUpdate {
        val available = mutableListOf(
            Capability.CAPABILITY_CLIPBOARD_READ,
            Capability.CAPABILITY_CLIPBOARD_WRITE,
            // App-owned MediaStore Downloads need no SAF tree or storage permission on API 31+.
            Capability.CAPABILITY_FILES,
            Capability.CAPABILITY_NOTIFICATION_ACTION_RESULTS,
            Capability.CAPABILITY_FEATURE_CONFIGURATION,
        )
        val unavailable = linkedMapOf<String, String>()
        if (BuildConfig.DISTRIBUTION != "play") available += Capability.CAPABILITY_CAPTURE_RETIREMENT_PROOF
        if (BuildConfig.DISTRIBUTION != "play" && com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.shell?.isAvailable == true) {
            available += Capability.CAPABILITY_PRIVILEGED_BRIDGE
        } else unavailable[Capability.CAPABILITY_PRIVILEGED_BRIDGE.name] = "shell_bridge_not_activated"
        if (com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current != null &&
            com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.hasNearbyPermissions(context)) {
            available += Capability.CAPABILITY_NEARBY_LINK
        } else unavailable[Capability.CAPABILITY_NEARBY_LINK.name] = "nearby_permission_required"
        if (com.xopmc.galaxybridge.internet.NativeInternetGateway.load()) {
            available += Capability.CAPABILITY_INTERNET_GATEWAY
        } else unavailable[Capability.CAPABILITY_INTERNET_GATEWAY.name] = "native_gateway_unavailable"

        if (EncodedVideoBus.captureState.value) {
            available += Capability.CAPABILITY_SCREEN_CAPTURE
            available += Capability.CAPABILITY_RECORDING
        } else {
            val screenReason = EncodedVideoBus.unavailableReason.value
                ?: CompanionScreenPrivacyPolicy.MEDIA_PROJECTION_CONSENT_REQUIRED
            unavailable[Capability.CAPABILITY_SCREEN_CAPTURE.name] = screenReason
            unavailable[Capability.CAPABILITY_RECORDING.name] = screenReason
        }
        unavailable[CompanionScreenPrivacyPolicy.PHYSICAL_SCREEN_OFF_CAPABILITY] =
            CompanionScreenPrivacyPolicy.PHYSICAL_SCREEN_OFF_UNAVAILABLE_REASON
        if (GalaxyAccessibilityService.isActive()) {
            available += Capability.CAPABILITY_INPUT_INJECTION
        } else {
            unavailable[Capability.CAPABILITY_INPUT_INJECTION.name] = "accessibility_service_disabled"
        }
        if (GalaxyNotificationListenerService.isActive()) {
            available += Capability.CAPABILITY_NOTIFICATIONS
        } else {
            unavailable[Capability.CAPABILITY_NOTIFICATIONS.name] = "notification_access_disabled"
        }

        if (EncodedAudioBus.captureState.value) {
            available += Capability.CAPABILITY_AUDIO_FORWARDING
        } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            unavailable[Capability.CAPABILITY_AUDIO_FORWARDING.name] = "record_audio_permission_required"
        } else {
            unavailable[Capability.CAPABILITY_AUDIO_FORWARDING.name] = "media_projection_audio_not_running_or_blocked"
        }
        unavailable[Capability.CAPABILITY_SMS.name] = "notification_actions_only"
        if (DistributionFeatures.telephonyEnabled(BuildConfig.DISTRIBUTION)) {
            val callRole = TelephonyBridge.hasDialerRole(context)
            val callPermissions = listOf(
                Manifest.permission.READ_PHONE_STATE,
                Manifest.permission.CALL_PHONE,
                Manifest.permission.READ_CALL_LOG,
                Manifest.permission.ANSWER_PHONE_CALLS,
            ).all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
            if (callRole && callPermissions) {
                available += Capability.CAPABILITY_CALLS
            } else if (callRole) {
                unavailable[Capability.CAPABILITY_CALLS.name] = "call_permissions_required"
            } else {
                unavailable[Capability.CAPABILITY_CALLS.name] = "default_dialer_role_required"
            }
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            available += Capability.CAPABILITY_CAMERA_STREAM
        } else {
            unavailable[Capability.CAPABILITY_CAMERA_STREAM.name] = "camera_permission_required"
        }
        unavailable[Capability.CAPABILITY_VIRTUAL_DISPLAY.name] = "enhanced_adb_required"

        val features = com.xopmc.galaxybridge.setup.DeviceFeaturePreferences(context)
        val featureCapabilities = mapOf(
            "screen" to listOf(Capability.CAPABILITY_SCREEN_CAPTURE, Capability.CAPABILITY_INPUT_INJECTION),
            "audio" to listOf(Capability.CAPABILITY_AUDIO_FORWARDING),
            "clipboard" to listOf(Capability.CAPABILITY_CLIPBOARD_READ, Capability.CAPABILITY_CLIPBOARD_WRITE),
            "files" to listOf(Capability.CAPABILITY_FILES),
            "notifications" to listOf(Capability.CAPABILITY_NOTIFICATIONS),
            "camera" to listOf(Capability.CAPABILITY_CAMERA_STREAM),
            "calls" to listOf(Capability.CAPABILITY_CALLS),
            "recording" to listOf(Capability.CAPABILITY_RECORDING),
            "internet" to listOf(Capability.CAPABILITY_INTERNET_GATEWAY),
        )
        featureCapabilities.forEach { (feature, capabilities) -> if (!features.isEnabled(feature)) {
            available.removeAll(capabilities.toSet())
            capabilities.forEach { unavailable[it.name] = "feature_disabled" }
        } }

        return CapabilityUpdate.newBuilder()
            .setTransport(TransportKind.TRANSPORT_KIND_COMPANION_LAN)
            .addAllAvailable(available)
            .putAllUnavailableReasons(unavailable)
            .build()
    }

}
