package com.xopmc.galaxybridge.transport.shell

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime

/** Only the shell UID with DUMP can consume a locally prepared, one-use activation ticket. */
class ShellBridgeAttachProvider : ContentProvider() {
    override fun onCreate() = true
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        // This check must precede any read or unparcel of attacker-supplied extras.
        val caller = Binder.getCallingUid()
        if (!ShellActivationTicketPolicy.admitsCaller(caller)) throw SecurityException("shell_attach_caller_rejected")
        val app = requireNotNull(context)
        app.enforceCallingPermission("android.permission.DUMP", "shell_attach_permission_required")
        if (method != "attach" || !ShellBridgePolicy.allowedDistribution(app.packageName, BuildConfig.DISTRIBUTION)) {
            throw SecurityException("shell_attach_unsupported")
        }
        val bridge = extras?.getBinder("bridge") ?: throw SecurityException("shell_attach_invalid")
        val boot = extras.getString("boot_generation").orEmpty()
        val token = extras.getString("token").orEmpty()
        val activationID = extras.getString("activation_id").orEmpty()
        val runtime = ForegroundConnectivityRuntime.current?.shell ?: throw SecurityException("foreground_owner_required")
        return try {
            val state = runtime.attach(caller, activationID, token, boot, bridge)
            Bundle().apply {
                putBoolean("available", state.available); putString("boot_generation", state.bootGeneration)
                putString("state", state.state); putString("error_code", state.errorCode)
            }
        } catch (error: Exception) {
            Bundle().apply {
                putBoolean("available", false); putString("boot_generation", boot)
                putString("state", "failed"); putString("error_code", ShellActivationDiagnostics.publicCode(error))
            }
        }
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = throw SecurityException("shell_attach_only")
    override fun getType(uri: Uri): String? = throw SecurityException("shell_attach_only")
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw SecurityException("shell_attach_only")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw SecurityException("shell_attach_only")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw SecurityException("shell_attach_only")
}
