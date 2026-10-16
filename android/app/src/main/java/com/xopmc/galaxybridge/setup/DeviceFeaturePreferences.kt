package com.xopmc.galaxybridge.setup

import android.content.Context

/** Phone policy belongs to its authenticated paired Mac, never the onboarding checklist. */
class DeviceFeaturePreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
    fun enabledIDs(): Set<String> = DeviceFeaturePolicy.enabledIDs(preferences.getStringSet(ENABLED_KEY, null))
    fun isEnabled(featureID: String): Boolean =
        if (featureID == "calls" && !preferences.contains(ENABLED_KEY)) true else featureID in enabledIDs()

    internal fun <T> withEnabled(featureID: String, action: () -> T): T? = synchronized(lock) {
        if (isEnabled(featureID)) action() else null
    }

    internal fun applyAuthenticated(request: DeviceFeatureRequest, authenticatedHostID: String,
        authenticatedSessionID: String, deviceID: String): String? = synchronized(lock) {
        // Re-read trust at the durable mutation point, not merely at socket admission.
        val pairedHost = preferences.getString("paired_host_id", null)
        if (pairedHost != authenticatedHostID) return@synchronized "feature_identity_mismatch"
        val revision = if (preferences.getString(HOST_KEY, null) == authenticatedHostID) preferences.getLong(REVISION_KEY, 0) else 0
        DeviceFeaturePolicy.rejection(request, authenticatedHostID, authenticatedSessionID, deviceID, revision)?.let { return@synchronized it }
        if (!preferences.edit().putStringSet(ENABLED_KEY, request.enabledIDs).putString(HOST_KEY, authenticatedHostID)
                .putLong(REVISION_KEY, request.revision).commit()) return@synchronized "feature_storage_failed"
        null
    }

    companion object {
        const val ENABLED_KEY = "device_feature_preferences_v1"
        private const val HOST_KEY = "device_feature_host_v1"
        private const val REVISION_KEY = "device_feature_revision_v1"
        private val lock = Any()
    }
}
