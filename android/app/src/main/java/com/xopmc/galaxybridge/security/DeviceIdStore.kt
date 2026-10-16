package com.xopmc.galaxybridge.security

import android.content.Context
import java.util.UUID

/** Pairing and LAN startup must advertise the same durably stored device ID. */
internal object DeviceIdStore {
    fun getOrCreate(context: Context): String {
        val preferences = context.applicationContext.getSharedPreferences("galaxybridge", Context.MODE_PRIVATE)
        return DeviceIdentityCoordinator.getOrCreateDeviceId(
            read = { preferences.getString("device_id", null) },
            generate = { UUID.randomUUID().toString() },
            commit = { preferences.edit().putString("device_id", it).commit() },
        )
    }
}
