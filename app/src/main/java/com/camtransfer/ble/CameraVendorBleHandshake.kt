package com.camtransfer.ble

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanResult
import android.content.Context
import android.util.Log
import kotlinx.coroutines.*
import java.util.UUID

private const val TAG = "CameraVendorBleHandshake"

@SuppressLint("MissingPermission")
class CameraVendorBleHandshake(private val context: Context) {

    private var gatt: BluetoothGatt? = null
    private var connected = CompletableDeferred<Unit>()
    private var servicesDiscovered = CompletableDeferred<List<BluetoothGattService>>()
    private var writeResult = CompletableDeferred<Boolean>()
    private var readResult = CompletableDeferred<ByteArray>()

    var wifiSSID: String? = null
        private set

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            Log.d(TAG, "GATT state=$newState status=$status")
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (!connected.isCompleted) connected.complete(Unit)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (!connected.isCompleted)
                        connected.completeExceptionally(Exception("GATT连接失败 status=$status"))
                    if (!servicesDiscovered.isCompleted)
                        servicesDiscovered.completeExceptionally(Exception("蓝牙断开"))
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            Log.d(TAG, "Services: ${g.services.size} status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS) servicesDiscovered.complete(g.services)
            else servicesDiscovered.completeExceptionally(Exception("Discovery failed: $status"))
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int
        ) {
            Log.d(TAG, "Write ${c.uuid.short()}: status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS) writeResult.complete(true)
            else writeResult.completeExceptionally(Exception("Write failed: $status"))
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt, c: BluetoothGattCharacteristic,
            value: ByteArray, status: Int
        ) {
            Log.d(TAG, "Read ${c.uuid.short()}: status=$status len=${value.size}")
            if (status == BluetoothGatt.GATT_SUCCESS) readResult.complete(value)
            else readResult.completeExceptionally(Exception("Read failed: $status"))
        }
    }

    suspend fun performHandshake(scanResult: ScanResult): CameraVendorBleProfileType {
        val scannedDevice = scanResult.device
        val scannedAddr = scannedDevice.address
        val deviceName = scannedDevice.name ?: ""

        val bondedAddr = resolveBondedAddress(scannedAddr, deviceName)
        val useAddr = bondedAddr ?: scannedAddr
        Log.d(TAG, "Scanned=$scannedAddr bonded=$bondedAddr using=$useAddr")

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val device = manager.adapter.getRemoteDevice(useAddr)

        connectGatt(device)
        val services = discoverServices()

        for (svc in services) {
            val chars = svc.characteristics.map { it.uuid.short() }
            if (chars.isNotEmpty()) Log.d(TAG, "  ${svc.uuid.short()}: $chars")
        }

        val serviceUuids = services.map { it.uuid }.toSet()
        val token = extractToken(scanResult)
        val hasModernPair = CameraVendorBleProfile.MODERN_PAIR_SERVICE in serviceUuids
        val hasLegacyPair = CameraVendorBleProfile.LEGACY_PAIR_SERVICE in serviceUuids
        Log.d(TAG, "modern=$hasModernPair legacy=$hasLegacyPair token=${token != null}")

        val pairService = when {
            hasModernPair -> CameraVendorBleProfile.MODERN_PAIR_SERVICE
            hasLegacyPair -> CameraVendorBleProfile.LEGACY_PAIR_SERVICE
            else -> throw Exception("未找到配对服务")
        }

        val pairChars = services.find { it.uuid == pairService }
            ?.characteristics?.map { it.uuid } ?: emptyList()
        val hasSecureStatus = CameraVendorBleProfile.SECURE_STATUS_CHAR in pairChars
        val hasPairToken = CameraVendorBleProfile.PAIR_TOKEN_CHAR in pairChars
        val hasIdentifier = CameraVendorBleProfile.IDENTIFIER_CHAR in pairChars

        val profile: CameraVendorBleProfileType

        if (token != null && hasPairToken) {
            Log.d(TAG, "=== Token flow ===")
            writeChar(pairService, CameraVendorBleProfile.PAIR_TOKEN_CHAR, token)
            if (hasIdentifier) writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
            profile = if (hasModernPair) CameraVendorBleProfileType.MODERN_TOKEN
                      else CameraVendorBleProfileType.LEGACY_BASIC
        } else if (hasSecureStatus) {
            Log.d(TAG, "=== Secure flow ===")
            profile = CameraVendorBleProfileType.MODERN_SECURE
            performSecureHandshake(pairService, hasIdentifier, device)
        } else if (hasIdentifier) {
            Log.d(TAG, "=== Identifier-only flow ===")
            writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
            profile = CameraVendorBleProfileType.MODERN_TOKEN
        } else {
            throw Exception("配对服务中没有可用的特征值")
        }

        readCameraName(device)
        Log.d(TAG, "Handshake done: profile=$profile ssid=$wifiSSID")
        return profile
    }

    private suspend fun performSecureHandshake(
        pairService: UUID, hasIdentifier: Boolean, device: BluetoothDevice
    ) {
        var status: ByteArray? = null
        var lastError: Exception? = null

        for (attempt in 1..3) {
            try {
                Log.d(TAG, "Secure status read attempt $attempt/3")
                status = readChar(pairService, CameraVendorBleProfile.SECURE_STATUS_CHAR)
                Log.d(TAG, "Secure status: ${status.hex()}")
                break
            } catch (e: Exception) {
                lastError = e
                Log.w(TAG, "Secure status read failed ($attempt/3): $e")
                if (isInsufficientEncryptionError(e) && attempt < 3) {
                    Log.d(TAG, "Encryption error, reconnecting...")
                    reconnect(device)
                } else if (attempt < 3) {
                    delay(4000)
                }
            }
        }

        if (status == null) {
            throw Exception(
                "安全握手状态读取失败。请确认：\n" +
                "1. 相机处于[配对注册]模式\n" +
                "2. 如果手机弹出蓝牙配对框，请点确认\n" +
                "3. 如果相机屏幕有提示，也请确认\n" +
                "原始错误: $lastError"
            )
        }

        if (status.size == 4) {
            val ack = byteArrayOf(status[0], status[1], status[2], 0x20)
            Log.d(TAG, "Secure ACK: ${ack.hex()}")
            writeChar(pairService, CameraVendorBleProfile.SECURE_STATUS_CHAR, ack)
        }

        if (hasIdentifier) {
            writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
        }
    }

    private fun resolveBondedAddress(scannedAddress: String, name: String): String? {
        if (name.isEmpty()) return null
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bonded = manager.adapter.bondedDevices ?: return null
        for (dev in bonded) {
            if (dev.address == scannedAddress) return scannedAddress
            if (dev.name != null && dev.name == name) {
                Log.d(TAG, "Resolved bonded address: ${dev.address} for name=$name")
                return dev.address
            }
        }
        return null
    }

    private suspend fun connectGatt(device: BluetoothDevice) {
        connected = CompletableDeferred()
        Log.d(TAG, "Connecting to ${device.name ?: device.address}...")
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        withTimeout(15_000) { connected.await() }
        Log.d(TAG, "GATT connected")
    }

    private suspend fun discoverServices(): List<BluetoothGattService> {
        servicesDiscovered = CompletableDeferred()
        gatt!!.discoverServices()
        return withTimeout(15_000) { servicesDiscovered.await() }
    }

    private suspend fun reconnect(device: BluetoothDevice) {
        Log.d(TAG, "Reconnecting...")
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        delay(1000)
        connectGatt(device)
        discoverServices()
    }

    private fun extractToken(scanResult: ScanResult): ByteArray? {
        val mfgData = scanResult.scanRecord?.manufacturerSpecificData ?: return null
        for (i in 0 until mfgData.size()) {
            val bytes = mfgData.valueAt(i)
            if (bytes != null && bytes.size >= 7) {
                val token = bytes.copyOfRange(3, 7)
                Log.d(TAG, "Mfg token: ${token.hex()}")
                return token
            }
        }
        return null
    }

    private suspend fun readCameraName(device: BluetoothDevice) {
        try {
            val raw = readChar(
                CameraVendorBleProfile.DEVICE_NAME_SERVICE, CameraVendorBleProfile.DEVICE_NAME_CHAR
            )
            val name = String(raw, Charsets.UTF_8).trim().replace("", "")
            if (name.isNotEmpty()) {
                wifiSSID = name
                Log.d(TAG, "Camera name → SSID: $name")
                return
            }
        } catch (e: Exception) {
            Log.w(TAG, "readCameraName failed: $e")
        }
        wifiSSID = device.name
        Log.d(TAG, "Fallback SSID: $wifiSSID")
    }

    private suspend fun writeChar(serviceUuid: UUID, charUuid: UUID, value: ByteArray) {
        val g = gatt ?: throw Exception("GATT disconnected")
        val svc = g.getService(serviceUuid) ?: throw Exception("Service missing")
        val ch = svc.getCharacteristic(charUuid) ?: throw Exception("Char missing")

        writeResult = CompletableDeferred()
        val wt = if (ch.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        g.writeCharacteristic(ch, value, wt)
        withTimeout(10_000) { writeResult.await() }
    }

    private suspend fun readChar(serviceUuid: UUID, charUuid: UUID): ByteArray {
        val g = gatt ?: throw Exception("GATT disconnected")
        val svc = g.getService(serviceUuid) ?: throw Exception("Service missing")
        val ch = svc.getCharacteristic(charUuid) ?: throw Exception("Char missing")

        readResult = CompletableDeferred()
        g.readCharacteristic(ch)
        return withTimeout(8_000) { readResult.await() }
    }

    fun disconnect() {
        gatt?.disconnect()
        gatt?.close()
        gatt = null
    }

    private fun isInsufficientEncryptionError(error: Exception): Boolean {
        val text = error.message?.lowercase() ?: ""
        return "encryption" in text || "133" in text || "5" in text
    }

    private fun appName() = "CamTransfer".toByteArray(Charsets.UTF_8)
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun UUID.short() = toString().take(8)
}
