package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult
import com.xopmc.galaxybridge.protocol.v1.ShellCaptureOptions
import com.xopmc.galaxybridge.protocol.v1.CaptureRetirementQuery
import com.xopmc.galaxybridge.protocol.v1.DisplayStateCommand
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.charset.CharacterCodingException
import org.junit.Assert.*
import org.junit.Test

class ShellBridgePolicyTest {
    private val lease = "69830b65-6352-4b3a-8a21-70bcda45787e"
    private val request = "d5e1590c-47fb-4d73-9ac2-45988ba0a876"
    @Test fun authenticatedRetirementStopsProducersBeforeTheirSharedDisplayOwner() {
        val registry = ShellStreamLeaseRegistry()
        val snapshot = ShellBridgeRequest.newBuilder().setRequestId(request).setLeaseId(lease).setBootGeneration(request)
            .setOperation(ShellBridgeRequest.Operation.START_DISPLAY_STATE).setDisplayState(DisplayStateCommand.getDefaultInstance()).build()
        assertTrue(registry.admitComposite("peer", "session", snapshot))
        val first = "10d52c21-4115-42fc-9d8e-5062bf2e92ef"
        val second = "c7ec9d2e-cbab-49b6-9c0c-d96ef03d2dbe"
        assertTrue(registry.admit("peer", "session", first))
        assertTrue(registry.admit("peer", "session", second))
        assertTrue(registry.admit("other", "session", request))
        assertEquals(listOf(first, second, lease), registry.owned("peer", "session"))
        assertEquals(listOf(request), registry.owned("other", "session"))
        registry.remove(first)
        assertEquals(listOf(second, lease), registry.owned("peer", "session"))
    }
    @Test fun compositeDisplayCommandsRequireTheirOwnTypedAuthenticatedChildLease() {
        val command = DisplayStateCommand.newBuilder().setAction(DisplayStateCommand.Action.APPLY)
            .setInteractive(true).setPanelPolicy(DisplayStateCommand.PanelPolicy.HIDE).setRevision(1).build()
        val base = ShellBridgeRequest.newBuilder().setRequestId(request).setLeaseId(lease).setBootGeneration(request)
            .setOperation(ShellBridgeRequest.Operation.START_DISPLAY_STATE).setDisplayState(command).build()
        assertTrue(ShellBridgePolicy.valid(base))
        assertTrue(ShellBridgePolicy.usesChildLease(base.operation))
        assertFalse(ShellBridgePolicy.readOnly(base.operation))
        assertTrue(ShellBridgePolicy.valid(base.toBuilder().setDisplayState(DisplayStateCommand.getDefaultInstance()).build()))
        assertTrue(ShellBridgePolicy.valid(base.toBuilder().setDisplayState(DisplayStateCommand.newBuilder()
            .setAction(DisplayStateCommand.Action.STATUS)).build()))
        val invalidCommands = listOf(command.toBuilder().setRevision(0).build(),
            command.toBuilder().setRevision(-1).build(), command.toBuilder().setActionValue(99).build(),
            command.toBuilder().setPanelPolicyValue(99).build(), command.toBuilder().setAction(DisplayStateCommand.Action.STATUS).build(),
            DisplayStateCommand.newBuilder().setInteractive(true).build(),
            DisplayStateCommand.newBuilder().setPanelPolicy(DisplayStateCommand.PanelPolicy.SHOW).build())
        for (invalid in invalidCommands) assertFalse(ShellBridgePolicy.valid(base.toBuilder().setDisplayState(invalid).build()))
        for (invalid in listOf(base.toBuilder().clearDisplayState().build(), base.toBuilder().clearBootGeneration().build(),
            base.toBuilder().clearLeaseId().build(), base.toBuilder().setPowerOn(true).build(),
            base.toBuilder().setOptions(ShellCaptureOptions.getDefaultInstance()).build(),
            base.toBuilder().setRetirement(CaptureRetirementQuery.getDefaultInstance()).build())) {
            assertFalse(ShellBridgePolicy.valid(invalid))
        }
        for (operation in listOf(ShellBridgeRequest.Operation.STATUS, ShellBridgeRequest.Operation.START_SCRCPY,
            ShellBridgeRequest.Operation.START_PANEL, ShellBridgeRequest.Operation.STOP, ShellBridgeRequest.Operation.VERIFY_RETIREMENT)) {
            assertFalse(ShellBridgePolicy.valid(base.toBuilder().setOperation(operation).build()))
        }
    }
    @Test fun compositeRetirementKindIsDistinctAndNeverAcquiresAnOwner() {
        val query = CaptureRetirementQuery.newBuilder().setKind(CaptureRetirementQuery.Kind.DISPLAY_STATE_CONTROLLER)
            .setPid(42).setProcessStartTicks(123456).build()
        val verify = ShellBridgeRequest.newBuilder().setRequestId(request).setBootGeneration(lease)
            .setOperation(ShellBridgeRequest.Operation.VERIFY_RETIREMENT).setRetirement(query).build()
        assertTrue(ShellBridgePolicy.valid(verify))
        assertTrue(ShellBridgePolicy.readOnly(verify.operation))
        assertFalse(ShellBridgePolicy.usesChildLease(verify.operation))
        val release = verify.toBuilder().setOperation(ShellBridgeRequest.Operation.RELEASE_RETIRED_RESOURCE)
            .setRetirement(query.toBuilder().setOwnedResourceId(lease)
                .setResourceSha256(com.google.protobuf.ByteString.copyFrom(ByteArray(32) { 1 }))).build()
        assertTrue(ShellBridgePolicy.valid(release))
        for (invalid in listOf(verify.toBuilder().setRetirement(query.toBuilder().setScid(18)).build(),
            verify.toBuilder().setRetirement(query.toBuilder().setPid(1)).build(),
            verify.toBuilder().setRetirement(query.toBuilder().setProcessStartTicks(0)).build(),
            verify.toBuilder().setDisplayState(DisplayStateCommand.getDefaultInstance()).build(),
            release.toBuilder().setRetirement(release.retirement.toBuilder().clearResourceSha256()).build())) {
            assertFalse(ShellBridgePolicy.valid(invalid))
        }
    }
    @Test fun retirementProofIsReadOnlyTypedAndNeverAcquiresAChildLease() {
        val support = ShellBridgeRequest.newBuilder().setRequestId(request).setBootGeneration(lease)
            .setOperation(ShellBridgeRequest.Operation.VERIFY_RETIREMENT)
            .setRetirement(CaptureRetirementQuery.newBuilder().setKind(CaptureRetirementQuery.Kind.PROBE_SUPPORT)).build()
        assertTrue(ShellBridgePolicy.valid(support))
        val capture = support.toBuilder().setRetirement(CaptureRetirementQuery.newBuilder()
            .setKind(CaptureRetirementQuery.Kind.SCRCPY_CAPTURE).setScid(18)).build()
        assertTrue(ShellBridgePolicy.valid(capture))
        val panel = support.toBuilder().setRetirement(CaptureRetirementQuery.newBuilder()
            .setKind(CaptureRetirementQuery.Kind.DISPLAY_POWER_CONTROLLER).setPid(42).setProcessStartTicks(123456)).build()
        assertTrue(ShellBridgePolicy.valid(panel))
        for (invalid in listOf(support.toBuilder().setLeaseId(lease).build(),
            support.toBuilder().setPowerOn(true).build(), support.toBuilder().clearRetirement().build(),
            support.toBuilder().setOptions(ShellCaptureOptions.getDefaultInstance()).build(),
            support.toBuilder().setBootGeneration("").build(),
            capture.toBuilder().setRetirement(capture.retirement.toBuilder().setScid(0)).build(),
            capture.toBuilder().setRetirement(capture.retirement.toBuilder().setScid(-1)).build(),
            capture.toBuilder().setRetirement(capture.retirement.toBuilder().setPid(42)).build(),
            panel.toBuilder().setRetirement(panel.retirement.toBuilder().setProcessStartTicks(0)).build(),
            panel.toBuilder().setRetirement(panel.retirement.toBuilder().setScid(18)).build(),
            support.toBuilder().setRetirement(support.retirement.toBuilder().setKindValue(99)).build())) {
            assertFalse(ShellBridgePolicy.valid(invalid))
        }
    }

    @Test fun resourceReleaseRequiresAnExactOwnedRuntimeAndNeverCreatesAChildLease() {
        val query = CaptureRetirementQuery.newBuilder().setKind(CaptureRetirementQuery.Kind.DISPLAY_POWER_CONTROLLER)
            .setPid(42).setProcessStartTicks(123456).setOwnedResourceId(lease)
            .setResourceSha256(com.google.protobuf.ByteString.copyFrom(ByteArray(32) { 1 })).build()
        val release = ShellBridgeRequest.newBuilder().setRequestId(request).setBootGeneration(lease)
            .setOperation(ShellBridgeRequest.Operation.RELEASE_RETIRED_RESOURCE).setRetirement(query).build()
        assertTrue(ShellBridgePolicy.valid(release))
        assertFalse(ShellBridgePolicy.usesChildLease(release.operation))
        assertFalse(ShellBridgePolicy.readOnly(release.operation))
        assertTrue(ShellBridgePolicy.readOnly(ShellBridgeRequest.Operation.VERIFY_RETIREMENT))
        assertFalse(ShellBridgePolicy.usesChildLease(ShellBridgeRequest.Operation.VERIFY_RETIREMENT))
        for (invalid in listOf(release.toBuilder().setRetirement(query.toBuilder().setOwnedResourceId("../path")).build(),
            release.toBuilder().setRetirement(query.toBuilder().clearResourceSha256()).build(),
            release.toBuilder().setRetirement(query.toBuilder().setPid(0)).build(),
            release.toBuilder().setRetirement(query.toBuilder().setProcessStartTicks(0)).build(),
            release.toBuilder().setOperation(ShellBridgeRequest.Operation.VERIFY_RETIREMENT).build())) {
            assertFalse(ShellBridgePolicy.valid(invalid))
        }
    }

    @Test fun activationPackageAllowlistNeverAcceptsRemoteOrPlayIdentities() {
        assertTrue(ShellBridgePolicy.allowedDistribution("com.xopmc.galaxybridge", "direct"))
        assertTrue(ShellBridgePolicy.allowedDistribution("com.xopmc.galaxybridge.internal", "internal"))
        assertFalse(ShellBridgePolicy.allowedDistribution("com.xopmc.galaxybridge", "play"))
        assertFalse(ShellBridgePolicy.allowedDistribution("com.xopmc.galaxybridge.internal", "direct"))
        assertFalse(ShellBridgePolicy.allowedDistribution("other.app", "internal"))
    }
    @Test fun activationNeverAcceptsPathsWhitespaceTokensOrNonCanonicalGenerations() {
        assertTrue(ShellBridgePolicy.activation("gb-shell.synthetic", "a".repeat(64), lease))
        for (name in listOf("/data/local/tmp/socket", "gb shell", "../shell", "x")) {
            assertFalse(ShellBridgePolicy.activation(name, "a".repeat(64), lease))
        }
        assertFalse(ShellBridgePolicy.activation("gb-shell.synthetic", "A".repeat(64), lease))
    }
    @Test fun onlyTypedBoundedCaptureOptionsCanReachPrivilegedProcess() {
        val base = ShellBridgeRequest.newBuilder().setRequestId(request).setLeaseId(lease).setBootGeneration(request)
            .setOperation(ShellBridgeRequest.Operation.START_SCRCPY)
        assertTrue(ShellBridgePolicy.valid(base.build()))
        assertFalse(ShellBridgePolicy.valid(base.clone().clearBootGeneration().build()))
        assertFalse(ShellBridgePolicy.valid(base.clone().setOperationValue(99).build()))
        for (options in listOf(ShellCaptureOptions.newBuilder().setPackageName("com.example;id").build(),
            ShellCaptureOptions.newBuilder().setCodec("sh").build(), ShellCaptureOptions.newBuilder().setMaxFps(1000).build(),
            ShellCaptureOptions.newBuilder().setWidth(1).setHeight(1).build())) {
            assertFalse(ShellBridgePolicy.valid(base.clone().setOptions(options).build()))
        }
    }
    @Test fun compositeLeaseRequiresFrozenSnapshotAndCannotBecomeALegacyOrForeignLease() {
        val registry = ShellStreamLeaseRegistry()
        val snapshot = ShellBridgeRequest.newBuilder().setRequestId(request).setLeaseId(lease).setBootGeneration(request)
            .setOperation(ShellBridgeRequest.Operation.START_DISPLAY_STATE).setDisplayState(DisplayStateCommand.getDefaultInstance()).build()
        val status = snapshot.toBuilder().setDisplayState(DisplayStateCommand.newBuilder().setAction(DisplayStateCommand.Action.STATUS)).build()
        val apply = snapshot.toBuilder().setDisplayState(DisplayStateCommand.newBuilder().setAction(DisplayStateCommand.Action.APPLY)
            .setInteractive(true).setRevision(1)).build()
        assertFalse(registry.admitComposite("peer", "session", apply))
        assertTrue(registry.admitComposite("peer", "session", snapshot))
        assertTrue(registry.isComposite("peer", "session", lease))
        assertFalse(registry.isComposite("other", "session", lease))
        assertFalse(registry.admit("peer", "session", lease))
        assertFalse(registry.declare("peer", "session", lease, listOf("$lease/video")))
        assertFalse(registry.admitComposite("peer", "session", status))
        val nativeHeader = ShellBridgeResult.newBuilder().setLeaseId(lease).setAvailable(true)
            .setState("display_state_snapshotted").setDisplayStateAcknowledgement(com.google.protobuf.ByteString.copyFromUtf8("bounded native header")).build()
        assertFalse(registry.confirmCompositeSnapshot("other", "session", lease, nativeHeader))
        assertFalse(registry.confirmCompositeSnapshot("peer", "session", lease, nativeHeader.toBuilder().clearDisplayStateAcknowledgement().build()))
        assertTrue(registry.confirmCompositeSnapshot("peer", "session", lease, nativeHeader))
        assertTrue(registry.admitComposite("peer", "session", status))
        assertTrue(registry.admitComposite("peer", "session", apply))
        assertTrue(registry.canWriteComposite("peer", "session", apply))
        assertFalse(registry.admitComposite("peer", "session", snapshot))
        assertTrue(registry.markCompositeStopping("peer", "session", lease))
        assertFalse(registry.canWriteComposite("peer", "session", apply))
        assertFalse(registry.admitComposite("peer", "session", status))
        val stopped = ShellBridgeResult.newBuilder().setLeaseId(lease).setAvailable(true).setState("stopped").build()
        assertFalse(registry.confirmsStopped("peer", "session", lease, stopped))
        assertFalse(registry.confirmsStopped("peer", "session", lease, stopped.toBuilder().setState("display_state_retired").build()))
        val proof = com.xopmc.galaxybridge.protocol.v1.CaptureRetirementProof.newBuilder()
            .setKind(CaptureRetirementQuery.Kind.DISPLAY_STATE_CONTROLLER).setPid(42).setProcessStartTicks(456)
            .setSupported(true).setAbsent(true).setDisplayStateTerminalAcknowledgement(com.google.protobuf.ByteString.copyFromUtf8("validated native terminal"))
        val retired = stopped.toBuilder().setState("display_state_retired").setRetirementProof(proof).build()
        assertTrue(registry.confirmsStopped("peer", "session", lease, retired))
        registry.remove(lease)
        assertFalse(registry.admit("peer", "new-session", lease))
        assertFalse(registry.admitComposite("peer", "new-session", snapshot))
        registry.clear()
        assertTrue(registry.admitComposite("peer", "new-session", snapshot))
    }
    @Test fun cancellingCompositeSnapshotBeforeItWasWrittenCannotBeReopenedByALateWriter() {
        val registry = ShellStreamLeaseRegistry()
        val snapshot = ShellBridgeRequest.newBuilder().setRequestId(request).setLeaseId(lease).setBootGeneration(request)
            .setOperation(ShellBridgeRequest.Operation.START_DISPLAY_STATE).setDisplayState(DisplayStateCommand.getDefaultInstance()).build()
        assertTrue(registry.admitComposite("peer", "session", snapshot))
        assertTrue(registry.canWriteComposite("peer", "session", snapshot))
        assertTrue(registry.markCompositeStopping("peer", "session", lease))
        assertFalse(registry.canWriteComposite("peer", "session", snapshot))
        val noStart = ShellBridgeResult.newBuilder().setLeaseId(lease).setAvailable(true).setState("display_state_not_started").build()
        assertTrue(registry.confirmsStopped("peer", "session", lease, noStart))
        registry.remove(lease)
        assertFalse(registry.admitComposite("peer", "session", snapshot))
    }
    @Test fun lostSnapshotHeaderAndLostStopAckCanRecoverOnlyForTheOriginalPeerSessionAndBoot() {
        val registry = ShellStreamLeaseRegistry()
        val snapshot = ShellBridgeRequest.newBuilder().setRequestId(request).setLeaseId(lease).setBootGeneration(request)
            .setOperation(ShellBridgeRequest.Operation.START_DISPLAY_STATE).setDisplayState(DisplayStateCommand.getDefaultInstance()).build()
        assertTrue(registry.admitComposite("peer", "session", snapshot))
        assertTrue(registry.admit("sibling", "other-session", request))
        assertTrue(registry.declare("sibling", "other-session", request, listOf("$request/control")))
        assertTrue(registry.markCompositeStopping("peer", "session", lease))
        val noStart = ShellBridgeResult.newBuilder().setRequestId(request).setLeaseId(lease).setBootGeneration(request)
            .setAvailable(true).setState("display_state_not_started").build()
        assertTrue(registry.retainCompositeRetirement("peer", "session", lease, noStart))
        registry.remove(lease)
        val retry = snapshot.toBuilder().setRequestId(lease).setOperation(ShellBridgeRequest.Operation.STOP).clearDisplayState().build()
        val recovered = requireNotNull(registry.cachedCompositeStop("peer", "session", retry))
        assertEquals(lease, recovered.requestId)
        assertEquals(noStart.toBuilder().setRequestId(lease).build(), recovered)
        assertNull(registry.cachedCompositeStop("other", "session", retry))
        assertNull(registry.cachedCompositeStop("peer", "new-session", retry))
        assertNull(registry.cachedCompositeStop("peer", "session", retry.toBuilder().setBootGeneration(lease).build()))
        assertNull(registry.cachedCompositeStop("peer", "session", snapshot))
        assertFalse(registry.admitComposite("peer", "session", snapshot))
        assertTrue(registry.allows("sibling", "other-session", "$request/control"))
        registry.clear()
        assertNull(registry.cachedCompositeStop("peer", "session", retry))
    }
    @Test fun declaredStreamsRemainPeerSessionAndLeaseBound() {
        val registry = ShellStreamLeaseRegistry()
        assertTrue(registry.admit("peer", "session", lease))
        assertFalse(registry.admit("other", "session", lease))
        assertFalse(registry.allows("peer", "session", "$lease/video"))
        assertTrue(registry.declare("peer", "session", lease, listOf("$lease/video", "$lease/control", "$lease/log")))
        assertTrue(registry.allows("peer", "session", "$lease/video"))
        assertTrue(registry.allows("peer", "session", "$lease/log"))
        assertFalse(registry.allows("peer", "old", "$lease/video"))
        assertFalse(registry.allows("peer", "session", "$lease/shell"))
        assertFalse(registry.declare("peer", "session", lease, listOf("$request/video")))
        registry.remove(lease)
        assertFalse(registry.allows("peer", "session", "$lease/video"))
    }
    @Test fun lifetimeOwnerClearRetiresAllStreamsAndRegistryIsBounded() {
        val registry = ShellStreamLeaseRegistry()
        for (index in 1..8) assertTrue(registry.admit("peer", "session", java.util.UUID(0, index.toLong()).toString()))
        assertFalse(registry.admit("peer", "session", java.util.UUID(0, 9).toString()))
        registry.clear()
        assertTrue(registry.owned("peer", "session").isEmpty())
    }
    @Test fun onlyConfirmedStoppedReceiptForCurrentOwnerAuthorizesRemoval() {
        val registry = ShellStreamLeaseRegistry()
        assertTrue(registry.admit("peer", "session", lease))
        val stopped = ShellBridgeResult.newBuilder().setLeaseId(lease).setAvailable(true).setState("stopped").build()
        assertTrue(registry.confirmsStopped("peer", "session", lease, stopped))
        for (reply in listOf(stopped.toBuilder().setState("failed").setErrorCode("shell_operation_failed").build(),
            stopped.toBuilder().setState("unknown").build(), stopped.toBuilder().setAvailable(false).build(),
            stopped.toBuilder().setErrorCode("shell_operation_failed").build(), stopped.toBuilder().setLeaseId(request).build(),
            stopped.toBuilder().addStreamIds("$lease/control").build())) {
            assertFalse(registry.confirmsStopped("peer", "session", lease, reply))
            assertTrue(registry.owns("peer", "session", lease))
        }
        assertFalse(registry.confirmsStopped("other", "session", lease, stopped))
        assertFalse(registry.confirmsStopped("peer", "old-session", lease, stopped))
        registry.remove(lease)
        assertTrue(registry.admit("peer", "new-session", lease))
        assertFalse(registry.confirmsStopped("peer", "session", lease, stopped))
        assertTrue(registry.owns("peer", "new-session", lease))
    }
    @Test fun privateFramesRejectInvalidSizeAndMalformedUtf8AndRoundTripUnicode() {
        val output = ByteArrayOutputStream()
        ShellBridgeWire.write(output, "synthetic — fixture")
        assertEquals("synthetic — fixture", ShellBridgeWire.read(ByteArrayInputStream(output.toByteArray())))
        assertThrows(IllegalArgumentException::class.java) { ShellBridgeWire.read(ByteArrayInputStream(byteArrayOf(0,0,0,0))) }
        assertThrows(IllegalArgumentException::class.java) { ShellBridgeWire.read(ByteArrayInputStream(byteArrayOf(127,127,127,127))) }
        assertThrows(CharacterCodingException::class.java) { ShellBridgeWire.read(ByteArrayInputStream(byteArrayOf(0,0,0,1,255.toByte()))) }
    }
}
