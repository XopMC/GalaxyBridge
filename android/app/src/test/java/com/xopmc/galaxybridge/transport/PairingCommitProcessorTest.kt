package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.core.P256Keys
import com.xopmc.galaxybridge.core.PairingTranscript
import com.xopmc.galaxybridge.protocol.v1.PairingCommit
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCommitProcessorTest {
    @Test
    fun signedResponseCandidateDoesNotPromoteUntilValidCommitThenAckIsIdempotent() {
        val keys = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }
        val mac = keys.generateKeyPair()
        val phone = keys.generateKeyPair()
        val candidate = candidate(
            macKey = P256Keys.x963Representation(mac.public),
            phoneKey = P256Keys.x963Representation(phone.public),
        )
        var promotions = 0
        var admitted = true
        val processor = PairingCommitProcessor(candidate, nowMillis = { 10_000 },isAdmitted={admitted})
        assertEquals(0, promotions)

        val validCommit = commit(candidate) { transcript ->
            Signature.getInstance("SHA256withECDSA").run {
                initSign(mac.private)
                update(transcript)
                sign()
            }
        }
        val first = processor.accept(
            validCommit,
            promote = { promotions++; true },
            signAcknowledgement = { transcript ->
                Signature.getInstance("SHA256withECDSA").run {
                    initSign(phone.private)
                    update(transcript)
                    sign()
                }
            },
        )
        assertNotNull(first)
        assertEquals(1, promotions)
        assertTrue(first!!.acknowledgement.committed)
        assertTrue(
            PairingTranscript.verify(
                first.acknowledgement.transcriptSignature.toByteArray(),
                first.acknowledgementTranscript,
                candidate.androidPublicKey,
            ),
        )

        val retry = processor.accept(
            validCommit,
            promote = { promotions++; true },
            signAcknowledgement = { error("cached acknowledgement must be reused") },
        )
        assertEquals(1, promotions)
        assertArrayEquals(
            first.acknowledgement.toByteArray(),
            retry!!.acknowledgement.toByteArray(),
        )
        admitted = false
        assertNull(processor.accept(validCommit,{promotions++;true},{error("revoked owner cannot sign")}))
        assertEquals(1,promotions)
    }

    @Test fun ownPreferencePromotionPreservesIdenticalAckButExternalRevocationDoesNot() {
        val keys=KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
        val mac=keys.generateKeyPair();val phone=keys.generateKeyPair()
        val candidate=candidate(P256Keys.x963Representation(mac.public),P256Keys.x963Representation(phone.public))
        val gate=PairingPromotionGate();var storedHost:String?=null;var storedKey:ByteArray?=null
        var admitted=true;var promotions=0;var retiredPriorResources=0
        val listener=PairingIdentityChangeListener({retiredPriorResources++},{
            if (!gate.preserve(storedHost,storedKey)) admitted=false
        })
        val processor=PairingCommitProcessor(candidate,nowMillis={10_000},isAdmitted={admitted})
        val signed=commit(candidate) { bytes -> Signature.getInstance("SHA256withECDSA").run {
            initSign(mac.private);update(bytes);sign()
        } }
        val first=processor.accept(signed,{
            gate.during(candidate.hostId,candidate.macPublicKey) {
                storedHost=candidate.hostId;storedKey=candidate.macPublicKey
                listener.changed("paired_host_id");listener.changed("paired_mac_key")
                promotions++;true
            }
        },{ bytes -> Signature.getInstance("SHA256withECDSA").run {initSign(phone.private);update(bytes);sign()} })
        assertNotNull(first);assertTrue(admitted);assertEquals(2,retiredPriorResources)
        val retry=processor.accept(signed,{error("ACK retry cannot promote twice")},{error("cached ACK must be reused")})
        assertArrayEquals(first!!.acknowledgement.toByteArray(),retry!!.acknowledgement.toByteArray())
        assertEquals(1,promotions)
        storedHost=null;storedKey=null;listener.changed("paired_host_id")
        assertFalse(admitted)
        assertNull(processor.accept(signed,{error("revoked")},{error("revoked")}))
    }

    @Test fun approvedConsentRevokedBeforeCommitCannotRecreateTrust() {
        val keys=KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
        val mac=keys.generateKeyPair();val phone=keys.generateKeyPair()
        val candidate=candidate(P256Keys.x963Representation(mac.public),P256Keys.x963Representation(phone.public))
        var admitted=true;var promotions=0
        val processor=PairingCommitProcessor(candidate,nowMillis={10_000},isAdmitted={admitted})
        val signed=commit(candidate) { bytes -> Signature.getInstance("SHA256withECDSA").run {
            initSign(mac.private);update(bytes);sign()
        } }
        admitted=false
        assertNull(processor.accept(signed,{promotions++;true},{error("revoked authority cannot sign")}))
        assertEquals(0,promotions)
    }

    @Test
    fun substitutedOrExpiredCommitNeverPromotes() {
        val keys = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }
        val mac = keys.generateKeyPair()
        val phone = keys.generateKeyPair()
        val candidate = candidate(
            macKey = P256Keys.x963Representation(mac.public),
            phoneKey = P256Keys.x963Representation(phone.public),
        )
        var promotions = 0
        val signed = commit(candidate) { transcript ->
            Signature.getInstance("SHA256withECDSA").run {
                initSign(mac.private)
                update(transcript)
                sign()
            }
        }
        val substituted = signed.toBuilder().setSessionId("other-session").build()
        val active = PairingCommitProcessor(candidate, nowMillis = { 10_000 })
        assertNull(active.accept(substituted, { promotions++; true }, { ByteArray(0) }))
        assertEquals(0, promotions)

        val expired = PairingCommitProcessor(candidate, nowMillis = { candidate.expiresAtMillis })
        assertNull(expired.accept(signed, { promotions++; true }, { ByteArray(0) }))
        assertEquals(0, promotions)
        assertFalse(expired.isCommitted)
    }

    @Test
    fun failedAtomicPromotionDoesNotEmitAcknowledgementAndCanRetry() {
        val keys = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"))
        }
        val mac = keys.generateKeyPair()
        val phone = keys.generateKeyPair()
        val candidate = candidate(
            macKey = P256Keys.x963Representation(mac.public),
            phoneKey = P256Keys.x963Representation(phone.public),
        )
        val signed = commit(candidate) { transcript ->
            Signature.getInstance("SHA256withECDSA").run {
                initSign(mac.private)
                update(transcript)
                sign()
            }
        }
        val processor = PairingCommitProcessor(candidate, nowMillis = { 10_000 })

        assertNull(processor.accept(signed, promote = { false }, signAcknowledgement = { ByteArray(0) }))
        assertFalse(processor.isCommitted)

        val retry = processor.accept(
            signed,
            promote = { true },
            signAcknowledgement = { transcript ->
                Signature.getInstance("SHA256withECDSA").run {
                    initSign(phone.private)
                    update(transcript)
                    sign()
                }
            },
        )
        assertNotNull(retry)
        assertTrue(processor.isCommitted)
    }

    private fun candidate(macKey: ByteArray, phoneKey: ByteArray) = PairingCommitCandidate(
        token = ByteArray(32) { 0x31 },
        clientNonce = ByteArray(32) { 0x32 },
        serverNonce = ByteArray(32) { 0x33 },
        macPublicKey = macKey,
        androidPublicKey = phoneKey,
        hostId = "12345678-1234-5678-90ab-1234567890ab",
        deviceId = "galaxy-s24-ultra",
        sessionId = "pairing-session-42",
        expiresAtMillis = 120_000,
    )

    private fun commit(
        candidate: PairingCommitCandidate,
        sign: (ByteArray) -> ByteArray,
    ): PairingCommit {
        val transcript = candidate.commitTranscript()
        return PairingCommit.newBuilder()
            .setHostId(candidate.hostId)
            .setDeviceId(candidate.deviceId)
            .setSessionId(candidate.sessionId)
            .setTranscriptSignature(com.google.protobuf.ByteString.copyFrom(sign(transcript)))
            .build()
    }
}
