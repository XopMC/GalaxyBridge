package com.xopmc.galaxybridge.nearby

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.security.SecureRandom
import java.util.UUID

/** Bootstrap only, never a media transport. All crypto/trust decisions belong to sessionFactory. */
class NearbyBlePeripheral(
    context: Context,
    private val isForegroundOwner: () -> Boolean,
    private val sessionFactory: (connectionID: String) -> NearbyGattSession,
    private val onError: (String) -> Unit,
    private val onStarted: () -> Unit = {},
) : AutoCloseable {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val manager = this.context.getSystemService(BluetoothManager::class.java)
    private val lifecycle = NearbyAdvertisingLifecycle()
    val isRunningRequested: Boolean get() = lifecycle.isRunningRequested
    private var server: BluetoothGattServer? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var generation = 0L
    private val peers = linkedMapOf<BluetoothDevice, Peer>()
    private class Peer(val session: NearbyGattSession) {
        val decoder = NearbyFrameDecoder()
        val chunks = ArrayDeque<ByteArray>()
        var queuedBytes = 0
        var chunkSize = 20
        var subscribed = false
        var sending = false
        var expiry: Runnable? = null
    }

    fun start() {
      // Reserve the queued start so another service refresh cannot enqueue a duplicate.
      lifecycle.begin(available = true)
      handler.post {
        if (!isForegroundOwner()) { lifecycle.stop(); onError("foreground_owner_required"); return@post }
        stopInternal()
        val token = ++generation
        try {
            val adapter = manager.adapter
            if (!lifecycle.begin(adapter != null && adapter.isEnabled && adapter.isMultipleAdvertisementSupported)) {
                onError("ble_advertising_unavailable"); return@post
            }
            val callback = object : BluetoothGattServerCallback() {
                override fun onServiceAdded(status: Int, service: BluetoothGattService) { handler.post {
                    if (token != generation) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) { onError("ble_service_failed"); stopInternal(); return@post }
                    runCatching { advertise(token) }.onFailure {
                        onError("ble_advertise_start_failed"); stopInternal()
                    }
                } }
                override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) { handler.post {
                    if (token != generation) return@post
                    if (newState == BluetoothProfile.STATE_DISCONNECTED) removePeer(device)
                    else if (newState == BluetoothProfile.STATE_CONNECTED) {
                        if (peers.size >= 2 || !isForegroundOwner()) { server?.cancelConnection(device); return@post }
                        try {
                            removePeer(device)
                            val peer = Peer(sessionFactory(UUID.randomUUID().toString()))
                            peers[device] = peer
                            peer.expiry = Runnable { if (peers[device] === peer && !peer.session.isAuthenticated) { server?.cancelConnection(device); removePeer(device) } }
                            handler.postDelayed(requireNotNull(peer.expiry), 120_000)
                        }
                        catch (_: Exception) { server?.cancelConnection(device); onError("ble_session_rejected") }
                    }
                } }
                override fun onMtuChanged(device: BluetoothDevice, mtu: Int) { handler.post {
                    if (token == generation) peers[device]?.chunkSize = (mtu - 3).coerceIn(20, 512)
                } }
                override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int,
                    characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean, responseNeeded: Boolean,
                    offset: Int, value: ByteArray) { handler.post {
                    if (token != generation) return@post
                    val peer = peers[device]
                    if (peer == null || characteristic.uuid != RX_UUID || preparedWrite || offset != 0 || value.size > 512) {
                        if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                        return@post
                    }
                    try {
                        peer.decoder.feed(value).forEach { frame -> peer.session.receive(frame).forEach { enqueue(device, peer, it) } }
                        if (peer.session.isAuthenticated) { peer.expiry?.let(handler::removeCallbacks); peer.expiry = null }
                        if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                    } catch (_: Exception) {
                        if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                        server?.cancelConnection(device); removePeer(device); onError("ble_bootstrap_rejected")
                    }
                } }
                override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
                    preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) { handler.post {
                    if (token != generation) return@post
                    val peer = peers[device]
                    val valid = peer != null && descriptor.uuid == CCCD_UUID && descriptor.characteristic.uuid == TX_UUID &&
                        !preparedWrite && offset == 0 && (value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE) ||
                        value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE))
                    if (valid) {
                        peer.subscribed = value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                        pump(device, peer)
                    }
                    if (responseNeeded) server?.sendResponse(device, requestId,
                        if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null)
                } }
                override fun onNotificationSent(device: BluetoothDevice, status: Int) { handler.post {
                    if (token != generation) return@post
                    val peer = peers[device] ?: return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) { server?.cancelConnection(device); removePeer(device); return@post }
                    peer.sending = false
                    pump(device, peer)
                } }
            }
            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(BluetoothGattCharacteristic(RX_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE))
            val tx = BluetoothGattCharacteristic(TX_UUID, BluetoothGattCharacteristic.PROPERTY_INDICATE, 0)
            tx.addDescriptor(BluetoothGattDescriptor(CCCD_UUID, BluetoothGattDescriptor.PERMISSION_WRITE))
            service.addCharacteristic(tx)
            server = manager.openGattServer(context, callback)
            check(server?.addService(service) == true)
        } catch (_: Exception) { onError("ble_permission_or_start_failed"); stopInternal() }
      }
    }

    private fun advertise(token: Long) {
        if (token != generation || !isForegroundOwner()) return
        val advertiser = manager.adapter?.bluetoothLeAdvertiser ?: run { onError("ble_advertising_unavailable"); stopInternal(); return }
        val hint = ByteArray(8).also(SecureRandom()::nextBytes)
        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) { handler.post {
                if (token == generation && isForegroundOwner()) onStarted()
            } }
            override fun onStartFailure(errorCode: Int) { handler.post {
                if (token == generation) { onError("ble_advertise_failed_$errorCode"); stopInternal() }
            } }
        }
        advertiseCallback = callback
        advertiser.startAdvertising(AdvertiseSettings.Builder().setConnectable(true)
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).setTimeout(0).build(),
            AdvertiseData.Builder().setIncludeDeviceName(false).addServiceUuid(ParcelUuid(SERVICE_UUID)).build(),
            AdvertiseData.Builder().setIncludeDeviceName(false).addServiceData(ParcelUuid(SERVICE_UUID), hint).build(), callback)
    }
    private fun enqueue(device: BluetoothDevice, peer: Peer, frame: ByteArray) {
        val bytes = NearbyFrameDecoder.encode(frame)
        check(peer.queuedBytes + bytes.size <= 131_072) { "ble_reply_backpressure" }
        bytes.asList().chunked(peer.chunkSize).forEach { peer.chunks.addLast(it.toByteArray()) }
        peer.queuedBytes += bytes.size
        pump(device, peer)
    }
    @Suppress("DEPRECATION")
    private fun pump(device: BluetoothDevice, peer: Peer) {
        if (!peer.subscribed || peer.sending || peer.chunks.isEmpty()) return
        val current = server ?: return
        val tx = current.getService(SERVICE_UUID)?.getCharacteristic(TX_UUID) ?: return
        val chunk = peer.chunks.removeFirst()
        peer.queuedBytes -= chunk.size
        peer.sending = true
        val accepted = if (Build.VERSION.SDK_INT >= 33) current.notifyCharacteristicChanged(device, tx, true, chunk) == 0
        else { tx.value = chunk; current.notifyCharacteristicChanged(device, tx, true) }
        if (!accepted) { current.cancelConnection(device); removePeer(device); onError("ble_indication_failed") }
    }
    private fun removePeer(device: BluetoothDevice) { peers.remove(device)?.let { peer -> peer.expiry?.let(handler::removeCallbacks); runCatching { peer.session.close() }; peer.chunks.clear() } }
    private fun stopInternal() {
        lifecycle.stop()
        ++generation
        advertiseCallback?.let { callback -> runCatching { manager.adapter?.bluetoothLeAdvertiser?.stopAdvertising(callback) } }
        advertiseCallback = null
        peers.keys.toList().forEach { device -> runCatching { server?.cancelConnection(device) }; removePeer(device) }
        runCatching { server?.close() }
        server = null
    }
    override fun close() {
        lifecycle.stop()
        if (Looper.myLooper() == handler.looper) stopInternal() else handler.post(::stopInternal)
    }
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("6e5a0001-6b47-4b8f-8f41-54f4a681e602")
        val RX_UUID: UUID = UUID.fromString("6e5a0002-6b47-4b8f-8f41-54f4a681e602")
        val TX_UUID: UUID = UUID.fromString("6e5a0003-6b47-4b8f-8f41-54f4a681e602")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
