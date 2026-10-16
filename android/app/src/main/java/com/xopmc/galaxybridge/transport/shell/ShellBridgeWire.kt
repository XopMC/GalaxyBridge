package com.xopmc.galaxybridge.transport.shell

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

internal object ShellBridgeWire {
    fun read(input: InputStream): String {
        val stream = DataInputStream(input)
        val count = stream.readInt()
        require(count in 1..65_536) { "shell_frame_size" }
        val bytes = ByteArray(count).also(stream::readFully)
        return Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    }
    fun write(output: OutputStream, value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        require(bytes.size in 1..65_536)
        DataOutputStream(output).apply { writeInt(bytes.size); write(bytes); flush() }
    }
}
