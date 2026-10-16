package com.xopmc.galaxybridge.internet

import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream

internal object GatewaySocksHandshake {
    /** Called only inside a separately authenticated, lease-admitted companion TLS channel. */
    fun acceptClient(input: InputStream, output: OutputStream) {
        val client = DataInputStream(input)
        require(client.readUnsignedByte() == 5) { "socks_version" }
        val count = client.readUnsignedByte()
        require(count in 1..32) { "socks_methods" }
        val methods = ByteArray(count).also(client::readFully)
        require(methods.any { it == 0.toByte() }) { "socks_transport_auth_required" }
        output.write(byteArrayOf(5, 0)); output.flush()
    }

    fun authenticateNative(input: InputStream, output: OutputStream, username: String, password: String) {
        require(username.matches(Regex("[a-f0-9]{64}")) && password.matches(Regex("[a-f0-9]{64}")))
        val server = DataInputStream(input)
        output.write(byteArrayOf(5, 1, 2)); output.flush()
        require(server.readUnsignedByte() == 5 && server.readUnsignedByte() == 2) { "native_auth_method" }
        val user = username.toByteArray(Charsets.US_ASCII)
        val pass = password.toByteArray(Charsets.US_ASCII)
        output.write(byteArrayOf(1, user.size.toByte()) + user + byteArrayOf(pass.size.toByte()) + pass); output.flush()
        require(server.readUnsignedByte() == 1 && server.readUnsignedByte() == 0) { "native_auth_rejected" }
    }
}
