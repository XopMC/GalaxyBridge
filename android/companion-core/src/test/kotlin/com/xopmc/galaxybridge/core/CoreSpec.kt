package com.xopmc.galaxybridge.core

import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreSpec {
    @Test
    fun companionRoutedFallbackUsesTheCrossPlatformStablePort() {
        assertEquals(46_737, CompanionRoutedFallback.PORT)
    }

    @Test
    fun companionScreenPrivacyReportsThePublicApiBoundaryAndLockStopReason() {
        assertEquals(
            "physical_screen_off_while_mirroring_requires_enhanced_adb",
            CompanionScreenPrivacyPolicy.PHYSICAL_SCREEN_OFF_UNAVAILABLE_REASON,
        )
        assertEquals(
            "media_projection_stopped_when_device_locked",
            CompanionScreenPrivacyPolicy.projectionUnavailableReason(deviceLocked = true),
        )
        assertEquals(
            "media_projection_consent_required",
            CompanionScreenPrivacyPolicy.projectionUnavailableReason(deviceLocked = false),
        )
    }

    @Test
    fun controlFramingSupportsFragmentedInput() {
        assertArrayEquals(
            byteArrayOf(0, 0, 0, 2, 0xCA.toByte(), 0xFE.toByte()),
            ControlFrameCodec.encode(byteArrayOf(0xCA.toByte(), 0xFE.toByte())),
        )

        val decoder = ControlFrameDecoder(maxPayloadLength = 1024)
        assertEquals(emptyList<ByteArray>(), decoder.append(byteArrayOf(0, 0)))
        assertEquals(emptyList<ByteArray>(), decoder.append(byteArrayOf(0, 2, 0xAA.toByte())))
        assertArrayEquals(
            byteArrayOf(0xAA.toByte(), 0xBB.toByte()),
            decoder.append(byteArrayOf(0xBB.toByte())).single(),
        )
    }

    @Test
    fun mediaFramingMatchesHeaderAndSupportsFragmentedInput() {
        val packet = MediaPacket(
            flags = MediaPacketFlags.CONFIGURATION or MediaPacketFlags.KEY_FRAME,
            epoch = 0x01020304u,
            presentationTimeUs = 0x0102030405060708uL,
            payload = byteArrayOf(0xAA.toByte(), 0xBB.toByte()),
        )
        val encoded = MediaPacketCodec.encode(packet)

        assertArrayEquals(
            byteArrayOf(
                3, 1, 2, 3, 4,
                1, 2, 3, 4, 5, 6, 7, 8,
                0, 0, 0, 2, 0xAA.toByte(), 0xBB.toByte(),
            ),
            encoded,
        )

        val decoder = MediaPacketDecoder(maxPayloadLength = 1024)
        assertEquals(emptyList<MediaPacket>(), decoder.append(encoded.copyOfRange(0, 10)))
        val decoded = decoder.append(encoded.copyOfRange(10, encoded.size)).single()
        assertEquals(packet.flags, decoded.flags)
        assertEquals(packet.epoch, decoded.epoch)
        assertEquals(packet.presentationTimeUs, decoded.presentationTimeUs)
        assertArrayEquals(packet.payload, decoded.payload)
    }

    @Test
    fun reconnectScheduleAndTransportCapabilitiesPreservePriority() {
        assertEquals(
            listOf(1_000L, 2_000L, 5_000L, 10_000L, 30_000L, 30_000L, 30_000L),
            ReconnectBackoff().let { backoff -> List(7) { backoff.nextDelayMillis() } },
        )
        assertEquals(
            TransportKind.USB_ADB,
            TransportSelector.preferred(
                setOf(TransportKind.COMPANION_LAN, TransportKind.WIRELESS_ADB, TransportKind.USB_ADB),
            ),
        )

        val routes = CapabilityResolver.routes(
            listOf(
                TransportSnapshot(
                    TransportKind.COMPANION_LAN,
                    isConnected = true,
                    capabilities = setOf(Capability.SCREEN, Capability.NOTIFICATIONS),
                ),
                TransportSnapshot(
                    TransportKind.USB_ADB,
                    isConnected = true,
                    capabilities = setOf(Capability.SCREEN, Capability.INPUT),
                ),
            ),
        )
        assertEquals(TransportKind.USB_ADB, routes[Capability.SCREEN])
        assertEquals(TransportKind.COMPANION_LAN, routes[Capability.NOTIFICATIONS])
    }

    @Test
    fun sessionStateMachineRecoversFromDegradedConnection() {
        val machine = DeviceSessionStateMachine(DeviceSessionState.DISCOVERED)
        listOf(
            DeviceSessionState.PAIRING,
            DeviceSessionState.CONNECTING,
            DeviceSessionState.CONNECTED,
            DeviceSessionState.DEGRADED,
            DeviceSessionState.RECONNECTING,
            DeviceSessionState.CONNECTED,
        ).forEach(machine::transitionTo)

        assertEquals(DeviceSessionState.CONNECTED, machine.state)
    }

    @Test
    fun normalizedCoordinatesAreClampedAndConvertedToPixels() {
        val geometry = DisplayGeometry(2208, 1768)

        assertEquals(PixelPoint(2207, 0), NormalizedPoint(1.25, -0.25).pixelPoint(geometry))
        assertEquals(PixelPoint(1104, 884), NormalizedPoint(0.5, 0.5).pixelPoint(geometry))
    }

    @Test
    fun clipboardLoopSuppressorRejectsLocalAndReplayedItems() {
        val localID = UUID.fromString("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        val suppressor = ClipboardLoopSuppressor(localID, capacity = 16)
        val local = suppressor.markPublished("local".encodeToByteArray())
        assertFalse(suppressor.shouldAccept(local))

        val remote = ClipboardItemIdentity(
            UUID.fromString("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            sequence = 7,
            contentSha256 = sha256("remote".encodeToByteArray()),
        )
        assertTrue(suppressor.shouldAccept(remote))
        assertFalse(suppressor.shouldAccept(remote))
    }

    @Test
    fun companionCapabilityResolverExplainsUnavailableFeatures() {
        val availability = CompanionCapabilityResolver.resolve(
            CompanionEnvironment(
                flavor = DistributionFlavor.PLAY,
                enhancedTransportConnected = false,
                mediaProjectionGranted = true,
                accessibilityEnabled = false,
                notificationAccessGranted = true,
                safTreeGranted = false,
                defaultDialerRole = false,
            ),
        )

        assertTrue(availability.getValue(Capability.SCREEN).available)
        assertEquals(
            UnavailableReason.ACCESSIBILITY_REQUIRED,
            availability.getValue(Capability.INPUT).reason,
        )
        assertEquals(
            UnavailableReason.ENHANCED_TRANSPORT_REQUIRED,
            availability.getValue(Capability.VIRTUAL_DISPLAY).reason,
        )
        assertTrue(availability.getValue(Capability.NOTIFICATIONS).available)
        assertTrue(availability.getValue(Capability.SMS).available)
        assertTrue(availability.getValue(Capability.CLIPBOARD_READ).available)
        assertTrue(availability.getValue(Capability.CLIPBOARD_WRITE).available)
        assertEquals(CapabilityAvailability(true), availability.getValue(Capability.FILES))
    }

    @Test
    fun mediaStoreFilesRemainReadyWithoutSafOrCapturePermissions() {
        for (flavor in DistributionFlavor.entries) {
            for (legacySafGrant in listOf(false, true)) {
                val environment = CompanionEnvironment(
                    flavor = flavor,
                    enhancedTransportConnected = false,
                    mediaProjectionGranted = false,
                    accessibilityEnabled = false,
                    notificationAccessGranted = false,
                    safTreeGranted = legacySafGrant,
                    defaultDialerRole = false,
                )
                val availability = CompanionCapabilityResolver.resolve(environment)
                assertEquals(CapabilityAvailability(true), availability.getValue(Capability.FILES))
                assertFalse(availability.getValue(Capability.SCREEN).available)
            }
        }
    }

    @Test
    fun pairingUriDecodesAndValidatesRequiredFields() {
        val uri = "galaxybridge://pair?v=1&host=12345678-1234-5678-90ab-1234567890ab" +
            "&port=47920&token=q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s" +
            "&fp=zc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc0&exp=220" +
            "&addr=192.168.42.10&addr=galaxybridge.local"

        val pairing = PairingUriCodec.decode(uri, nowEpochSeconds = 100)

        assertEquals(1u, pairing.version)
        assertEquals(listOf("192.168.42.10", "galaxybridge.local"), pairing.addresses)
        assertEquals(32, pairing.token.size)
        assertEquals(220L, pairing.expiresAtEpochSeconds)
    }

    @Test
    fun pairingAndAdbBindingSignaturesRejectTampering() {
        val keyGenerator = p256KeyGenerator()
        val macKey = keyGenerator.generateKeyPair()
        val phoneKey = keyGenerator.generateKeyPair()
        val macPublicKey = P256Keys.x963Representation(macKey.public)
        val phonePublicKey = P256Keys.x963Representation(phoneKey.public)
        val token = ByteArray(32) { 0xAB.toByte() }
        val transcript = PairingTranscript.make(
            token,
            ByteArray(32) { 0x11 },
            ByteArray(32) { 0x22 },
            macPublicKey,
            phonePublicKey,
        )
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(macKey.private)
            update(transcript)
            sign()
        }
        assertTrue(PairingTranscript.verify(signature, transcript, macPublicKey))
        val tampered = transcript.copyOf().apply {
            this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte()
        }
        assertFalse(PairingTranscript.verify(signature, tampered, macPublicKey))

        val adbSerial = "R5CX123456A"
        val hostID = "5A67F995-2B6B-43EF-91F3-82822F69C05F"
        val adbNonce = ByteArray(32) { 0xA5.toByte() }
        val adbTranscript = ADBBindingTranscript.make(hostID, adbSerial, adbNonce, phonePublicKey)
        val adbSignature = Signature.getInstance("SHA256withECDSA").run {
            initSign(phoneKey.private)
            update(adbTranscript)
            sign()
        }
        assertTrue(
            ADBBindingTranscript.verify(adbSignature, hostID, adbSerial, adbNonce, phonePublicKey),
        )
        assertFalse(
            ADBBindingTranscript.verify(adbSignature, hostID, "tampered", adbNonce, phonePublicKey),
        )
    }

    @Test
    fun pairingCommitAndAcknowledgementBindSessionAndBothDeviceIds() {
        val keyGenerator = p256KeyGenerator()
        val macKey = keyGenerator.generateKeyPair()
        val phoneKey = keyGenerator.generateKeyPair()
        val macPublicKey = P256Keys.x963Representation(macKey.public)
        val phonePublicKey = P256Keys.x963Representation(phoneKey.public)
        val commit = PairingTranscript.makeCommit(
            token = ByteArray(32) { 0x41 },
            clientNonce = ByteArray(32) { 0x42 },
            serverNonce = ByteArray(32) { 0x43 },
            macPublicKey = macPublicKey,
            androidPublicKey = phonePublicKey,
            hostId = "12345678-1234-5678-90ab-1234567890ab",
            deviceId = "galaxy-s24-ultra",
            sessionId = "pairing-session-42",
        )
        val commitSignature = Signature.getInstance("SHA256withECDSA").run {
            initSign(macKey.private)
            update(commit)
            sign()
        }
        assertTrue(PairingTranscript.verify(commitSignature, commit, macPublicKey))

        val substituted = PairingTranscript.makeCommit(
            token = ByteArray(32) { 0x41 },
            clientNonce = ByteArray(32) { 0x42 },
            serverNonce = ByteArray(32) { 0x43 },
            macPublicKey = macPublicKey,
            androidPublicKey = phonePublicKey,
            hostId = "12345678-1234-5678-90ab-1234567890ab",
            deviceId = "galaxy-s24-ultra",
            sessionId = "substituted-session",
        )
        assertFalse(PairingTranscript.verify(commitSignature, substituted, macPublicKey))

        val acknowledgement = PairingTranscript.makeCommitAcknowledgement(commit, commitSignature)
        val acknowledgementSignature = Signature.getInstance("SHA256withECDSA").run {
            initSign(phoneKey.private)
            update(acknowledgement)
            sign()
        }
        assertTrue(PairingTranscript.verify(acknowledgementSignature, acknowledgement, phonePublicKey))
    }

    @Test
    fun tlsSessionAuthenticationTranscriptSignatureVerifies() {
        val macKey = p256KeyGenerator().generateKeyPair()
        val macPublicKey = P256Keys.x963Representation(macKey.public)
        val transcript = SessionAuthenticationTranscript.make(
            "mac-device",
            "session-1",
            ByteArray(32) { 0x44 },
            123_456,
            macPublicKey,
        )
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(macKey.private)
            update(transcript)
            sign()
        }

        assertTrue(PairingTranscript.verify(signature, transcript, macPublicKey))
    }

    private fun p256KeyGenerator(): KeyPairGenerator =
        KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }
}
