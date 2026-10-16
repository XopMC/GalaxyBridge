package com.xopmc.galaxybridge.internet

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream

internal object DnsWirePolicy {
    fun readQuery(input: InputStream): ByteArray {
        val stream = DataInputStream(input)
        val count = stream.readUnsignedShort()
        require(count in 12..65_535) { "dns_wire_size" }
        val query = ByteArray(count).also(stream::readFully)
        require(query[2].toInt() and 0x80 == 0) { "dns_query_required" }
        return query
    }
    fun writeAnswer(output: OutputStream, query: ByteArray, answer: ByteArray) {
        require(answer.size in 12..65_535 && answer[0] == query[0] && answer[1] == query[1] &&
            answer[2].toInt() and 0x80 != 0) { "dns_response_mismatch" }
        DataOutputStream(output).apply { writeShort(answer.size); write(answer); flush() }
    }
}
