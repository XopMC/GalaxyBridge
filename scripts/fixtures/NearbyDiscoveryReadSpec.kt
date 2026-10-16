package com.xopmc.galaxybridge.nearby

import java.util.UUID

internal data class DiscoveryReadDevice(val id: Int)
internal class DiscoveryReadCharacteristic(val uuid: UUID)
internal object DiscoveryReadGatt { const val GATT_SUCCESS = 0; const val GATT_FAILURE = 257 }
internal class DiscoveryReadHandler { fun post(action: () -> Unit) = action() }
internal class DiscoveryReadServer {
    data class Response(val status: Int, val offset: Int, val value: ByteArray?)
    val responses = mutableListOf<Response>()
    fun sendResponse(device: DiscoveryReadDevice, requestId: Int, status: Int, offset: Int, value: ByteArray?) {
        responses += Response(status, offset, value)
    }
}
@Suppress("UNNECESSARY_SAFE_CALL")
internal class NearbyDiscoveryReadFixture {
    val handler = DiscoveryReadHandler()
    val server = DiscoveryReadServer()
    val metadata = NearbyDiscoveryMetadata.encode("Samsung", "SM-S928B", ByteArray(65).apply { this[0] = 4 })
    val peers = mutableMapOf(DiscoveryReadDevice(1) to Unit)
    val METADATA_UUID = UUID.fromString("6e5a0004-6b47-4b8f-8f41-54f4a681e602")
    var foreground = true
    var token = 1L
    var generation = 1L
    fun isForegroundOwner() = foreground
    fun discoveryMetadata() = metadata
    // ACTUAL_READ_CALLBACK
}

object NearbyDiscoveryReadSpec {
    @JvmStatic fun main(args: Array<String>) {
        val fixture = NearbyDiscoveryReadFixture()
        val device = DiscoveryReadDevice(1)
        val characteristic = DiscoveryReadCharacteristic(fixture.METADATA_UUID)
        fixture.onCharacteristicReadRequest(device, 1, 0, characteristic)
        check(fixture.server.responses.last().value!!.contentEquals(fixture.metadata))
        fixture.onCharacteristicReadRequest(device, 2, 5, characteristic)
        check(fixture.server.responses.last().value!!.contentEquals(fixture.metadata.copyOfRange(5, fixture.metadata.size)))
        fixture.onCharacteristicReadRequest(device, 3, fixture.metadata.size, characteristic)
        check(fixture.server.responses.last().value!!.isEmpty())
        for (offset in listOf(-1, fixture.metadata.size + 1)) {
            fixture.onCharacteristicReadRequest(device, 4, offset, characteristic)
            check(fixture.server.responses.last().status == DiscoveryReadGatt.GATT_FAILURE && fixture.server.responses.last().value == null)
        }
        fixture.onCharacteristicReadRequest(device, 5, 0, DiscoveryReadCharacteristic(UUID.randomUUID()))
        check(fixture.server.responses.last().status == DiscoveryReadGatt.GATT_FAILURE)
        fixture.onCharacteristicReadRequest(DiscoveryReadDevice(2), 6, 0, characteristic)
        check(fixture.server.responses.last().status == DiscoveryReadGatt.GATT_FAILURE)
        fixture.foreground = false
        fixture.onCharacteristicReadRequest(device, 7, 0, characteristic)
        check(fixture.server.responses.last().status == DiscoveryReadGatt.GATT_FAILURE)
        val before = fixture.server.responses.size
        fixture.generation++
        fixture.onCharacteristicReadRequest(device, 8, 0, characteristic)
        check(fixture.server.responses.size == before)
        println("PASS actual Android read callback: bounded public bytes, ATT offsets, peer/owner/generation fences, no bootstrap dependency")
    }
}
