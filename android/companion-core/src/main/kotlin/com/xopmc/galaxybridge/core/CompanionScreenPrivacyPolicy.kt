package com.xopmc.galaxybridge.core

/**
 * Public-API boundary for Companion LAN screen sharing.
 *
 * Android 15 QPR1 and newer stop MediaProjection when the device locks. A
 * normal application therefore cannot both switch the physical display off
 * and keep MediaProjection running. Galaxy Bridge reports that limitation
 * instead of invoking GLOBAL_ACTION_LOCK_SCREEN and pretending the stream can
 * continue.
 */
object CompanionScreenPrivacyPolicy {
    const val PHYSICAL_SCREEN_OFF_CAPABILITY = "CAPABILITY_PHYSICAL_SCREEN_OFF"
    const val PHYSICAL_SCREEN_OFF_UNAVAILABLE_REASON =
        "physical_screen_off_while_mirroring_requires_enhanced_adb"
    const val MEDIA_PROJECTION_STOPPED_WHEN_LOCKED =
        "media_projection_stopped_when_device_locked"
    const val MEDIA_PROJECTION_CONSENT_REQUIRED = "media_projection_consent_required"

    fun projectionUnavailableReason(deviceLocked: Boolean): String =
        if (deviceLocked) MEDIA_PROJECTION_STOPPED_WHEN_LOCKED
        else MEDIA_PROJECTION_CONSENT_REQUIRED
}
