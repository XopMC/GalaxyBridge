package com.xopmc.galaxybridge.transport.shell

import com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest
import com.xopmc.galaxybridge.protocol.v1.ShellCaptureOptions
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.charset.CharacterCodingException
import org.junit.Assert.*
import org.junit.Test

class ShellBridgePolicyTest {
    private val lease = "69830b65-6352-4b3a-8a21-70bcda45787e"
    private val request = "d5e1590c-47fb-4d73-9ac2-45988ba0a876"
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
    @Test fun privateFramesRejectInvalidSizeAndMalformedUtf8AndRoundTripUnicode() {
        val output = ByteArrayOutputStream()
        ShellBridgeWire.write(output, "synthetic — fixture")
        assertEquals("synthetic — fixture", ShellBridgeWire.read(ByteArrayInputStream(output.toByteArray())))
        assertThrows(IllegalArgumentException::class.java) { ShellBridgeWire.read(ByteArrayInputStream(byteArrayOf(0,0,0,0))) }
        assertThrows(IllegalArgumentException::class.java) { ShellBridgeWire.read(ByteArrayInputStream(byteArrayOf(127,127,127,127))) }
        assertThrows(CharacterCodingException::class.java) { ShellBridgeWire.read(ByteArrayInputStream(byteArrayOf(0,0,0,1,255.toByte()))) }
    }
}
