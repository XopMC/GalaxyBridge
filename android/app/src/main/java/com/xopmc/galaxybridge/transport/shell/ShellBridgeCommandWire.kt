package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest

/** Fixed private broker fields; neither callers nor capture options supply verbs or argv. */
internal object ShellBridgeCommandWire {
    fun fields(request: ShellBridgeRequest, boot: String, compositeStop: Boolean = false): Map<String, Any> {
        require(ShellBridgePolicy.valid(request) && ShellBridgePolicy.uuid(boot))
        require(!compositeStop || request.operation == ShellBridgeRequest.Operation.STOP)
        val fields = linkedMapOf<String, Any>("request_id" to request.requestId, "lease_id" to request.leaseId,
            "boot_generation" to boot, "operation" to request.operationValue)
        if (request.operation == ShellBridgeRequest.Operation.START_DISPLAY_STATE) {
            val command = request.displayState
            fields["display_state"] = mapOf("action" to command.actionValue, "interactive" to command.interactive,
                "panel_policy" to command.panelPolicyValue, "revision" to command.revision)
        } else {
            val options = request.options
            fields["power_on"] = request.powerOn
            fields["options"] = mapOf("scid" to options.scid, "display_id" to options.displayId, "package_name" to options.packageName,
                "max_size" to options.maxSize, "max_fps" to options.maxFps, "video_bit_rate" to options.videoBitRate,
                "codec" to options.codec, "width" to options.width, "height" to options.height, "audio" to options.audio, "control" to options.control)
        }
        if (compositeStop) fields["display_state_stop"] = true
        if (request.hasRetirement()) {
            val query = request.retirement
            fields["retirement"] = mapOf("kind" to query.kindValue, "scid" to query.scid, "pid" to query.pid,
                "process_start_ticks" to query.processStartTicks, "owned_resource_id" to query.ownedResourceId,
                "resource_sha256" to query.resourceSha256.toByteArray().joinToString("") { "%02x".format(it.toInt() and 0xff) })
        }
        return fields
    }
}
