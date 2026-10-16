package com.xopmc.galaxybridge.internet

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import org.junit.Assert.*
import org.junit.Test

class DnsWirePolicyTest {
    @Test fun allDnsRecordTypesRemainOpaqueAndTransactionIdIsPreserved() {
        // HTTPS type65 and arbitrary remaining bytes are forwarded unchanged, not synthesized A records.
        val query = byteArrayOf(42,7,1,0,0,1,0,0,0,0,0,0,0,0,65,0,1)
        val framed = ByteArrayOutputStream().also { DataOutputStream(it).apply { writeShort(query.size); write(query) } }
        assertArrayEquals(query, DnsWirePolicy.readQuery(ByteArrayInputStream(framed.toByteArray())))
        val answer = query.copyOf().apply { this[2] = 0x81.toByte() }
        val output = ByteArrayOutputStream()
        DnsWirePolicy.writeAnswer(output, query, answer)
        assertArrayEquals(answer, output.toByteArray().copyOfRange(2, output.size()))
    }
    @Test fun truncatedPacketsResponsesAsQueriesAndWrongTransactionRepliesFailClosed() {
        assertThrows(IllegalArgumentException::class.java) { DnsWirePolicy.readQuery(ByteArrayInputStream(byteArrayOf(0,1,0))) }
        val query = ByteArray(12)
        val wrong = ByteArray(12).apply { this[0] = 1; this[2] = 0x80.toByte() }
        assertThrows(IllegalArgumentException::class.java) { DnsWirePolicy.writeAnswer(ByteArrayOutputStream(), query, wrong) }
    }
}
