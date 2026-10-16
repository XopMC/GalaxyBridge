package com.xopmc.galaxybridge.transport.shell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime
import org.json.JSONObject

/** Only UID shell/system with DUMP may supply the private endpoint of an ADB-launched process. */
class ShellBridgeActivationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION || !ShellBridgePolicy.allowedDistribution(context.packageName, BuildConfig.DISTRIBUTION)) {
            resultCode = 2; resultData = "shell_activation_unsupported"; return
        }
        val runtime = ForegroundConnectivityRuntime.current?.shell
        if (runtime == null) { resultCode = 3; resultData = "foreground_owner_required"; return }
        if (intent.getStringExtra("operation") == "status") {
            val state = runtime.status()
            resultCode = 0; resultData = receipt(state.available, state.bootGeneration, state.state, state.errorCode); return
        }
        if (intent.getStringExtra("operation") == "deactivate") {
            runtime.deactivate(); resultCode = 0; resultData = receipt(false, "", "stopped", ""); return
        }
        val name = intent.getStringExtra("socket_name").orEmpty()
        val token = intent.getStringExtra("token").orEmpty()
        val boot = intent.getStringExtra("boot_generation").orEmpty()
        if (intent.getStringExtra("operation") != "prepare" || !ShellBridgePolicy.activation(name, token, boot)) {
            resultCode = 2; resultData = "invalid_shell_activation"; return
        }
        try {
            val state = runtime.prepare(name, token, boot)
            resultCode = 0; resultData = receipt(state.available, state.bootGeneration, state.state, state.errorCode)
        } catch (_: Exception) {
            resultCode = 3; resultData = receipt(false, boot, "failed", "shell_prepare_failed")
        }
    }

    private fun receipt(available: Boolean, boot: String, state: String, error: String) = JSONObject()
        .put("available", available).put("boot_generation", boot).put("state", state).put("error_code", error).toString()
    companion object {
        const val ACTION = "com.xopmc.galaxybridge.ACTIVATE_SHELL_BRIDGE"
    }
}
