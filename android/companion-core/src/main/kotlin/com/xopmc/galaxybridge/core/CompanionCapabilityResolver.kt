package com.xopmc.galaxybridge.core

enum class DistributionFlavor {
    INTERNAL,
    PLAY,
}

enum class UnavailableReason {
    MEDIA_PROJECTION_REQUIRED,
    ACCESSIBILITY_REQUIRED,
    NOTIFICATION_ACCESS_REQUIRED,
    SAF_TREE_REQUIRED,
    NOTIFICATION_ACTIONS_REQUIRED,
    DEFAULT_DIALER_ROLE_REQUIRED,
    ENHANCED_TRANSPORT_REQUIRED,
}

data class CapabilityAvailability(
    val available: Boolean,
    val reason: UnavailableReason? = null,
)

data class CompanionEnvironment(
    val flavor: DistributionFlavor,
    val enhancedTransportConnected: Boolean,
    val mediaProjectionGranted: Boolean,
    val accessibilityEnabled: Boolean,
    val notificationAccessGranted: Boolean,
    val safTreeGranted: Boolean,
    val defaultDialerRole: Boolean,
)

object CompanionCapabilityResolver {
    fun resolve(environment: CompanionEnvironment): Map<Capability, CapabilityAvailability> {
        val enhanced = environment.enhancedTransportConnected
        val screen = environment.mediaProjectionGranted || enhanced
        return mapOf(
            Capability.SCREEN to availability(
                screen,
                UnavailableReason.MEDIA_PROJECTION_REQUIRED,
            ),
            Capability.INPUT to availability(
                environment.accessibilityEnabled || enhanced,
                UnavailableReason.ACCESSIBILITY_REQUIRED,
            ),
            Capability.AUDIO to availability(
                environment.mediaProjectionGranted || enhanced,
                UnavailableReason.MEDIA_PROJECTION_REQUIRED,
            ),
            Capability.CLIPBOARD_READ to CapabilityAvailability(true),
            Capability.CLIPBOARD_WRITE to CapabilityAvailability(true),
            // App-owned MediaStore Downloads are available without a persisted SAF grant.
            Capability.FILES to CapabilityAvailability(true),
            Capability.NOTIFICATIONS to availability(
                environment.notificationAccessGranted,
                UnavailableReason.NOTIFICATION_ACCESS_REQUIRED,
            ),
            Capability.SMS to availability(
                environment.notificationAccessGranted,
                UnavailableReason.NOTIFICATION_ACTIONS_REQUIRED,
            ),
            Capability.CALLS to availability(
                environment.defaultDialerRole,
                UnavailableReason.DEFAULT_DIALER_ROLE_REQUIRED,
            ),
            Capability.CAMERA to CapabilityAvailability(true),
            Capability.VIRTUAL_DISPLAY to availability(
                enhanced,
                UnavailableReason.ENHANCED_TRANSPORT_REQUIRED,
            ),
            Capability.RECORDING to availability(
                screen,
                UnavailableReason.MEDIA_PROJECTION_REQUIRED,
            ),
        )
    }

    private fun availability(
        available: Boolean,
        reason: UnavailableReason,
    ): CapabilityAvailability = CapabilityAvailability(
        available = available,
        reason = reason.takeUnless { available },
    )
}
