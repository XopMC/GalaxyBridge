package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.TransferAck
import org.junit.Assert.*
import org.junit.Test

class FileSendPolicyTest {
    @Test fun onlyDirectAndInternalExposeSender() {
        assertTrue(FileSendPolicy.enabled("direct"))
        assertTrue(FileSendPolicy.enabled("internal"))
        assertFalse(FileSendPolicy.enabled("play"))
        assertFalse(FileSendPolicy.enabled("unknown"))
        assertEquals(BuildConfig.DISTRIBUTION != "play", AndroidOutgoingFiles.enabled)
    }
    @Test fun onlyOneGrantedContentUriCanEnterSharePreview() {
        assertTrue(FileSendPolicy.acceptsShare("android.intent.action.SEND", "content", 1, true))
        assertFalse(FileSendPolicy.acceptsShare("android.intent.action.SEND", "file", 1, true))
        assertFalse(FileSendPolicy.acceptsShare("android.intent.action.SEND", "content", 1, false))
        assertFalse(FileSendPolicy.acceptsShare("android.intent.action.SEND", "content", 2, true))
        assertFalse(FileSendPolicy.acceptsShare("android.intent.action.SEND_MULTIPLE", "content", 1, true))
        assertFalse(FileSendPolicy.acceptsShare(null, null, 0, true))
    }
    @Test fun ackUsesExistingWireTagAndDedicatedFileRoute() {
        val wire = Envelope.newBuilder().setTransferAck(TransferAck.newBuilder()
            .setTransferId("fixture").setConfirmedOffset(17).setComplete(true).setPublishedName("copy (1).bin")).build()
        val decoded = Envelope.parseFrom(wire.toByteArray())
        assertEquals(21, decoded.payloadCase.number)
        assertEquals(CompanionControlPayloadKind.TRANSFER_ACK, CompanionControlPayloadPolicy.classify(decoded))
        assertEquals("copy (1).bin", decoded.transferAck.publishedName)
    }
}
