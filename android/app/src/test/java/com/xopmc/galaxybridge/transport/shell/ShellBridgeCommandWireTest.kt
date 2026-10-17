package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.CaptureRetirementQuery
import com.xopmc.galaxybridge.protocol.v1.DisplayStateCommand
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import org.junit.Assert.*
import org.junit.Test

class ShellBridgeCommandWireTest {
    private val boot = "69830b65-6352-4b3a-8a21-70bcda45787e"
    private val lease = "d5e1590c-47fb-4d73-9ac2-45988ba0a876"
    private fun request(operation: ShellBridgeRequest.Operation) = ShellBridgeRequest.newBuilder()
        .setRequestId(boot).setLeaseId(lease).setBootGeneration(boot).setOperation(operation)
    @Test fun compositeCommandsReachNativeWithoutAnyMediaOptionsOrLegacyPowerBit() {
        val snapshot = request(ShellBridgeRequest.Operation.START_DISPLAY_STATE)
            .setDisplayState(DisplayStateCommand.getDefaultInstance()).build()
        val fields = ShellBridgeCommandWire.fields(snapshot, boot)
        assertEquals(setOf("request_id", "lease_id", "boot_generation", "operation", "display_state"), fields.keys)
        assertEquals(8, fields["operation"])
        assertEquals(mapOf("action" to 0, "interactive" to false, "panel_policy" to 0, "revision" to 0L), fields["display_state"])
        val apply = snapshot.toBuilder().setDisplayState(DisplayStateCommand.newBuilder().setAction(DisplayStateCommand.Action.APPLY)
            .setInteractive(true).setPanelPolicy(DisplayStateCommand.PanelPolicy.HIDE).setRevision(17)).build()
        assertEquals(mapOf("action" to 2, "interactive" to true, "panel_policy" to 1, "revision" to 17L),
            ShellBridgeCommandWire.fields(apply, boot)["display_state"])
    }
    @Test fun compositeStopHasAnExplicitPrivateKindEvenWhenSnapshotHasNotReachedNative() {
        val stop = request(ShellBridgeRequest.Operation.STOP).build()
        assertFalse(ShellBridgeCommandWire.fields(stop, boot).containsKey("display_state_stop"))
        assertEquals(true, ShellBridgeCommandWire.fields(stop, boot, compositeStop = true)["display_state_stop"])
        assertFalse(ShellBridgeCommandWire.fields(stop, boot, compositeStop = true).containsKey("display_state"))
        assertThrows(IllegalArgumentException::class.java) {
            ShellBridgeCommandWire.fields(request(ShellBridgeRequest.Operation.START_SCRCPY).build(), boot, compositeStop = true)
        }
    }
    @Test fun fullDisplayStateRetirementNeverBecomesALegacyBooleanPanelQuery() {
        val query = request(ShellBridgeRequest.Operation.VERIFY_RETIREMENT).clearLeaseId()
            .setRetirement(CaptureRetirementQuery.newBuilder().setKind(CaptureRetirementQuery.Kind.DISPLAY_STATE_CONTROLLER)
                .setPid(42).setProcessStartTicks(456)).build()
        val fields = ShellBridgeCommandWire.fields(query, boot)
        val retirement = fields["retirement"] as Map<*, *>
        assertEquals(3, retirement["kind"])
        assertEquals(42, retirement["pid"])
        assertEquals(456L, retirement["process_start_ticks"])
        assertEquals(0, retirement["scid"])
        assertFalse(fields.containsKey("display_state"))
    }
}
