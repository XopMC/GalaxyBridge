package com.xopmc.galaxybridge.setup

/** Wire IDs are deliberately independent of permission/setup UI and never include telephony roles. */
internal data class DeviceFeatureRequest(
    val hostID: String, val sessionID: String, val deviceID: String,
    val requestID: String, val revision: Long, val enabledIDs: Set<String>,
)

internal object DeviceFeaturePolicy {
    val shippingIDs = setOf("screen", "applications", "audio", "clipboard", "files", "notifications", "camera", "recording", "internet")
    val supportedIDs = shippingIDs + "calls" // Optional: existing dialer-role phones only; never initial setup permissions.
    fun canUsePanel(enabledIDs: Set<String>): Boolean = "screen" in enabledIDs || "applications" in enabledIDs
    fun enabledIDs(stored: Set<String>?): Set<String> = stored?.intersect(supportedIDs) ?: shippingIDs
    fun rejection(request: DeviceFeatureRequest, hostID: String, sessionID: String, deviceID: String, revision: Long): String? = when {
        request.hostID != hostID || request.sessionID != sessionID || request.deviceID != deviceID -> "feature_identity_mismatch"
        !request.requestID.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) -> "invalid_feature_request"
        request.revision <= 0 || request.revision <= revision -> "stale_feature_revision"
        request.enabledIDs.size > supportedIDs.size || request.enabledIDs.any { it.length > 32 || it !in supportedIDs } -> "unsupported_feature"
        else -> null
    }
}
