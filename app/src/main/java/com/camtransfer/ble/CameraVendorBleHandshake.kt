package com.camtransfer.ble

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.camtransfer.service.CameraBluetoothPermissionPolicy
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration
import com.camtransfer.wifi.CameraVendorWifiNetworkConfigurationPolicy
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
    private var descriptorWriteResult = CompletableDeferred<Boolean>()
    private val observedCharacteristicValues = mutableMapOf<UUID, ByteArray>()
    private var connectedDevice: BluetoothDevice? = null
    private var hasWrittenPairingIdentifier = false
    private var hasPendingHandshakeSummary = false
    private var secureIdentificationNumberAlreadyPaired = false
    private var cameraDeviceName: String? = null
    private var cameraSerialNumber: String? = null
    private var preferredWifiNetwork: CameraVendorWifiNetworkConfiguration? = null

    var wifiSSID: String? = null
        private set
    var wifiPassphrase: String? = null
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

        @Suppress("DEPRECATION")
        @Deprecated("Deprecated in Android 13")
        override fun onCharacteristicRead(
            g: BluetoothGatt,
            c: BluetoothGattCharacteristic,
            status: Int
        ) {
            val value = c.value ?: ByteArray(0)
            Log.d(TAG, "Read ${c.uuid.short()}: status=$status len=${value.size}")
            if (status == BluetoothGatt.GATT_SUCCESS) readResult.complete(value)
            else readResult.completeExceptionally(Exception("Read failed: $status"))
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            Log.d(TAG, "Descriptor write ${descriptor.characteristic.uuid.short()}: status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS) descriptorWriteResult.complete(true)
            else descriptorWriteResult.completeExceptionally(Exception("Descriptor write failed: $status"))
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            c: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            observedCharacteristicValues[c.uuid] = value
            Log.d(TAG, "Notify ${c.uuid.short()}: ${value.hex()}")
        }

        @Suppress("DEPRECATION")
        @Deprecated("Deprecated in Android 13")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            val value = c.value ?: ByteArray(0)
            observedCharacteristicValues[c.uuid] = value
            Log.d(TAG, "Notify ${c.uuid.short()}: ${value.hex()}")
        }
    }

    suspend fun performHandshake(
        scanResult: ScanResult,
        activateTransfer: Boolean = false,
        mode: CameraVendorBleHandshakeMode = CameraVendorBleHandshakeMode.Pairing,
    ): CameraVendorBleProfileType {
        val scannedDevice = scanResult.device
        val scannedAddr = scannedDevice.address
        val deviceName = scannedDevice.name ?: ""

        val bondedAddr = resolveBondedAddress(scannedAddr, deviceName)
        val useAddr = bondedAddr ?: scannedAddr
        Log.d(TAG, "Scanned=$scannedAddr bonded=$bondedAddr using=$useAddr")

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val device = manager.adapter.getRemoteDevice(useAddr)
        return performHandshakeWithDevice(
            device = device,
            advertisedName = deviceName,
            token = extractToken(scanResult),
            activateTransfer = activateTransfer,
            mode = mode,
        )
    }

    suspend fun performHandshake(
        device: BluetoothDevice,
        activateTransfer: Boolean = false,
        autoConnect: Boolean = false,
        mode: CameraVendorBleHandshakeMode = CameraVendorBleHandshakeMode.Pairing,
    ): CameraVendorBleProfileType {
        return performHandshakeWithDevice(
            device = device,
            advertisedName = device.name ?: "",
            token = null,
            activateTransfer = activateTransfer,
            autoConnect = autoConnect,
            mode = mode,
        )
    }

    private suspend fun performHandshakeWithDevice(
        device: BluetoothDevice,
        advertisedName: String,
        token: ByteArray?,
        activateTransfer: Boolean,
        autoConnect: Boolean = false,
        mode: CameraVendorBleHandshakeMode,
    ): CameraVendorBleProfileType {
        connectedDevice = device
        hasWrittenPairingIdentifier = false
        hasPendingHandshakeSummary = false
        secureIdentificationNumberAlreadyPaired = false

        connectGatt(device, autoConnect)
        val services = discoverServices()
        val coordinator = CameraVendorBleHandshakeCoordinator()

        for (svc in services) {
            coordinator.registerServiceForCharacteristicDiscovery(svc.uuid.toString())
            val chars = svc.characteristics.map { it.uuid.short() }
            if (chars.isNotEmpty()) Log.d(TAG, "  ${svc.uuid.short()}: $chars")
            coordinator.completeCharacteristicDiscovery(svc.uuid.toString())
        }
        readHandshakeMetadata(services, coordinator)
        subscribeToNotifiableCharacteristics(services, coordinator)

        val serviceUuids = services.map { it.uuid }.toSet()
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

        if (!mode.shouldRunPairingHandshake) {
            Log.d(TAG, "=== Remembered gallery flow ===")
            profile = when {
                hasModernPair && hasSecureStatus -> CameraVendorBleProfileType.MODERN_SECURE
                hasModernPair -> CameraVendorBleProfileType.MODERN_TOKEN
                hasLegacyPair -> CameraVendorBleProfileType.LEGACY_BASIC
                else -> CameraVendorBleProfileType.UNKNOWN
            }
        } else if (token != null && hasPairToken) {
            if (!coordinator.canStartHandshake(hasIdentifierCharacteristic = hasIdentifier)) {
                throw Exception(coordinator.waitReason(false, hasIdentifier, hasConnectedDeviceIdentification = false))
            }
            coordinator.markHandshakeStarted()
            Log.d(TAG, "=== Token flow ===")
            writeChar(pairService, CameraVendorBleProfile.PAIR_TOKEN_CHAR, token)
            if (hasIdentifier) writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
            hasWrittenPairingIdentifier = hasIdentifier
            hasPendingHandshakeSummary = true
            profile = if (hasModernPair) CameraVendorBleProfileType.MODERN_TOKEN
                      else CameraVendorBleProfileType.LEGACY_BASIC
        } else if (hasSecureStatus) {
            if (!coordinator.canStartSecureHandshake(
                    hasConnectedDeviceNameCharacteristic = hasIdentifier,
                    hasConnectedDeviceIdentificationCharacteristic = hasSecureStatus,
                )
            ) {
                throw Exception(coordinator.waitReason(true, hasIdentifier, hasSecureStatus))
            }
            coordinator.markHandshakeStarted()
            Log.d(TAG, "=== Secure flow ===")
            profile = CameraVendorBleProfileType.MODERN_SECURE
            performSecureHandshake(pairService, hasIdentifier, device, mode)
        } else if (hasIdentifier) {
            if (!coordinator.canStartHandshake(hasIdentifierCharacteristic = true)) {
                throw Exception(coordinator.waitReason(false, hasIdentifier, hasConnectedDeviceIdentification = false))
            }
            coordinator.markHandshakeStarted()
            Log.d(TAG, "=== Identifier-only flow ===")
            writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
            hasWrittenPairingIdentifier = true
            hasPendingHandshakeSummary = true
            profile = CameraVendorBleProfileType.MODERN_TOKEN
        } else {
            throw Exception("配对服务中没有可用的特征值")
        }

        refreshReferenceAppNetworkConfig()
        readCameraName(device)
        if (activateTransfer) {
            performReferenceAppTransferActivation()
        }
        Log.d(TAG, "Handshake done: profile=$profile ssid=$wifiSSID")
        return profile
    }

    suspend fun prepareTransferActivation(
        preferCompressedDownloads: Boolean = CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads(),
    ) {
        writeTransferActivationRequest(preferCompressedDownloads)
        waitForTransferWifiReady()
    }

    suspend fun writeTransferActivationRequest(
        preferCompressedDownloads: Boolean = CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads(),
    ) {
        writeReferenceAppTransferActivationRequest(preferCompressedDownloads)
    }

    suspend fun waitForTransferWifiReady() {
        if (CameraVendorBleTransferActivationPolicy.shouldFastHandoffAfterCommandWrites()) {
            Log.d(TAG, "Transfer activation commands written; fast handoff to WiFi/PTP")
            return
        }
        waitForReferenceAppApReady()
    }

    fun disconnectForWifiHandoff() {
        if (CameraVendorBleTransferActivationPolicy.shouldActivelyDisconnectBluetoothBeforeWifi()) {
            Log.d(TAG, "Disconnecting BLE for WiFi/PTP handoff")
            disconnect()
        }
    }

    suspend fun refreshWifiConfigurations(): List<CameraVendorWifiNetworkConfiguration> {
        refreshReferenceAppNetworkConfig()
        return wifiConfigurations()
    }

    suspend fun refreshReferenceAppWifiConfiguration(): CameraVendorWifiNetworkConfiguration? {
        refreshReferenceAppNetworkConfig()
        return preferredWifiNetwork
    }

    fun referenceAppWifiConfigurations(): List<CameraVendorWifiNetworkConfiguration> =
        preferredWifiNetwork?.let { listOf(it) }.orEmpty()

    fun wifiConfigurations(): List<CameraVendorWifiNetworkConfiguration> {
        return CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = cameraDeviceName ?: wifiSSID,
            serialNumber = cameraSerialNumber,
            preferredWifiNetwork = preferredWifiNetwork,
        )
    }

    fun cameraName(): String {
        return cameraDeviceName ?: wifiSSID ?: connectedDevice?.name ?: "CAMERA_VENDOR"
    }

    fun cameraSerial(): String {
        return cameraSerialNumber ?: ""
    }

    fun bluetoothAddress(): String? {
        return connectedDevice?.address
    }

    fun canCompletePhonePairingConfirmation(): Boolean {
        return CameraVendorCameraPairingConfirmationPolicy.canCompleteQueuedPhoneConfirmation(
            hasWrittenIdentifier = hasWrittenPairingIdentifier,
            hasPendingHandshakeSummary = hasPendingHandshakeSummary,
            hasQueuedPhoneConfirmation = true,
        )
    }

    fun hasCompletedCameraPairingAck(): Boolean {
        return hasWrittenPairingIdentifier && hasPendingHandshakeSummary
    }

    fun hasLiveGattConnection(): Boolean {
        return gatt != null && connectedDevice != null
    }

    fun hasRequiredTransferActivationCharacteristics(): Boolean {
        val required = listOf(
            CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_CHAR,
            CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_EX_CHAR,
            CameraVendorBleProfile.IMAGE_RESIZE_SETTING_CHAR,
            CameraVendorBleProfile.LAUNCH_REQUEST_CHAR,
            CameraVendorBleProfile.AP_STATE_CHAR,
        )
        return hasLiveGattConnection() && required.all { findCharacteristic(it) != null }
    }

    fun currentSystemBondState(): Int {
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            return CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_NONE
        }
        return connectedDevice?.bondState?.toPairingPolicyBondState()
            ?: CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_NONE
    }

    suspend fun waitForSystemBondSettled(timeoutMs: Long = 5_000L): Boolean {
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) return true
        val device = connectedDevice ?: return true
        val settledState = if (device.bondState == BluetoothDevice.BOND_BONDING) {
            withTimeoutOrNull(timeoutMs) {
                while (device.bondState == BluetoothDevice.BOND_BONDING) {
                    delay(100)
                }
                device.bondState
            } ?: device.bondState
        } else {
            device.bondState
        }
        Log.d(TAG, "System bond state after pairing confirmation: $settledState")
        return CameraVendorCameraPairingConfirmationPolicy.canSaveConfirmedPairing(
            hasCompletedCameraAck = hasCompletedCameraPairingAck(),
            systemBondState = settledState.toPairingPolicyBondState(),
        )
    }

    suspend fun confirmCameraPairingSucceeded() {
        if (!canCompletePhonePairingConfirmation()) {
            throw Exception("相机端还没有完成识别号 ACK，不能确认配对")
        }
        if (CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation(
                hasWrittenIdentifier = hasWrittenPairingIdentifier,
                hasPendingHandshakeSummary = hasPendingHandshakeSummary,
                shouldBypassManualConfirmation = shouldBypassManualPairingConfirmation(),
                systemBondState = currentSystemBondState(),
            )
        ) {
            confirmCameraSidePairingAfterPhoneConfirmation()
        }
    }

    private suspend fun performSecureHandshake(
        pairService: UUID,
        hasIdentifier: Boolean,
        device: BluetoothDevice,
        mode: CameraVendorBleHandshakeMode,
    ) {
        var lastError: Exception? = null
        val maxAttempts = CameraVendorBlePairingPolicy.maxSecureHandshakeAttempts(mode)

        for (attempt in 1..maxAttempts) {
            try {
                for (step in CameraVendorBlePairingPolicy.secureSteps(hasIdentifier)) {
                    when (step) {
                        CameraVendorBleSecurePairingStep.WRITE_CONNECTED_DEVICE_NAME -> {
                            Log.d(TAG, "Writing connected device name before secure identification read")
                            writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
                        }
                        CameraVendorBleSecurePairingStep.READ_IDENTIFICATION_NUMBER -> Unit
                        CameraVendorBleSecurePairingStep.WRITE_IDENTIFICATION_ACK -> Unit
                    }
                }

                Log.d(TAG, "Secure status read attempt $attempt/3")
                val status = readChar(
                    pairService,
                    CameraVendorBleProfile.SECURE_STATUS_CHAR,
                    timeoutMs = CameraVendorBlePairingPolicy.SECURE_IDENTIFICATION_READ_TIMEOUT_MS,
                )
                Log.d(TAG, "Secure status: ${status.hex()}")

                val ack = CameraVendorBlePairingPolicy.identificationAckPayload(status)
                    ?: throw Exception("安全握手识别号长度异常")
                secureIdentificationNumberAlreadyPaired =
                    CameraVendorBlePairingPolicy.isAlreadyPairedIdentificationNumber(status)
                if (secureIdentificationNumberAlreadyPaired) {
                    Log.d(TAG, "Secure identification number already has paired application bit")
                }
                if (CameraVendorBlePairingPolicy.shouldWriteIdentificationAckDuringHandshake(hasAckPayload = true)) {
                    Log.d(TAG, "Secure ACK during handshake: ${ack.hex()}")
                    writeChar(pairService, CameraVendorBleProfile.SECURE_STATUS_CHAR, ack)
                    hasWrittenPairingIdentifier = true
                    hasPendingHandshakeSummary = true
                }
                return
            } catch (e: Exception) {
                lastError = e
                Log.w(TAG, "Secure handshake failed ($attempt/$maxAttempts): $e")
                if (mode == CameraVendorBleHandshakeMode.Pairing) {
                    DiagnosticLog.append(
                        context,
                        TAG,
                        "Fresh secure pairing failed; stop without automatic retry",
                        e,
                    )
                }
                if (isInsufficientEncryptionError(e) && attempt < maxAttempts) {
                    Log.d(TAG, "Encryption error, reconnecting...")
                    reconnect(device)
                } else if (attempt < maxAttempts) {
                    delay(4000)
                }
            }
        }

        throw Exception(
            "蓝牙配对没有完成，已停在当前步骤。请确认：\n" +
            "1. 相机处于[配对注册]模式\n" +
            "2. 如果手机弹出蓝牙配对框，请点确认\n" +
            "3. 如果相机屏幕有提示，也请确认\n" +
            "如果相机没有显示配对成功，请退出相机配对注册后重新进入，再重试。\n" +
            "原始错误: $lastError"
        )
    }

    private suspend fun confirmCameraSidePairingAfterPhoneConfirmation() {
        val device = connectedDevice ?: throw Exception("没有可重新确认的相机连接")
        Log.d(TAG, "Phone confirmed pairing; rediscovering services to complete camera-side confirmation")
        val services = runCatching {
            rediscoverServicesForConfirmation()
        }.getOrElse { error ->
            Log.w(TAG, "Service rediscovery for phone confirmation failed, reconnecting: $error")
            reconnect(device)
        }

        val pairService = when {
            services.any { it.uuid == CameraVendorBleProfile.MODERN_PAIR_SERVICE } ->
                CameraVendorBleProfile.MODERN_PAIR_SERVICE
            services.any { it.uuid == CameraVendorBleProfile.LEGACY_PAIR_SERVICE } ->
                CameraVendorBleProfile.LEGACY_PAIR_SERVICE
            else -> throw Exception("重新确认时未找到配对服务")
        }
        val pairChars = services.find { it.uuid == pairService }
            ?.characteristics?.map { it.uuid } ?: emptyList()
        val hasSecureStatus = CameraVendorBleProfile.SECURE_STATUS_CHAR in pairChars
        val hasConnectedDeviceName = CameraVendorBleProfile.IDENTIFIER_CHAR in pairChars

        if (hasSecureStatus) {
            if (hasConnectedDeviceName) {
                Log.d(TAG, "Phone confirmation: writing connected device name before ACK replay")
                writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
            }
            val status = readChar(
                pairService,
                CameraVendorBleProfile.SECURE_STATUS_CHAR,
                timeoutMs = CameraVendorBlePairingPolicy.SECURE_IDENTIFICATION_READ_TIMEOUT_MS,
            )
            Log.d(TAG, "Phone confirmation secure status: ${status.hex()}")
            val ack = CameraVendorBlePairingPolicy.identificationAckPayload(status)
                ?: throw Exception("重新确认时识别号长度异常")
            Log.d(TAG, "Phone confirmation replay ACK: ${ack.hex()}")
            writeChar(pairService, CameraVendorBleProfile.SECURE_STATUS_CHAR, ack)
        } else if (hasConnectedDeviceName) {
            Log.d(TAG, "Phone confirmation: replaying connected device name on identifier-only flow")
            writeChar(pairService, CameraVendorBleProfile.IDENTIFIER_CHAR, appName())
        } else {
            throw Exception("重新确认时没有可写入的相机配对特征")
        }

        hasWrittenPairingIdentifier = true
        hasPendingHandshakeSummary = true
        delay(500)
    }

    private fun Int.toPairingPolicyBondState(): Int =
        when (this) {
            BluetoothDevice.BOND_BONDED ->
                CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDED
            BluetoothDevice.BOND_BONDING ->
                CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDING
            else ->
                CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_NONE
        }

    private fun shouldBypassManualPairingConfirmation(): Boolean {
        return secureIdentificationNumberAlreadyPaired
    }

    private fun resolveBondedAddress(scannedAddress: String, name: String): String? {
        if (name.isEmpty()) return null
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) return null
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

    private suspend fun connectGatt(device: BluetoothDevice, autoConnect: Boolean = false) {
        connected = CompletableDeferred()
        Log.d(TAG, "Connecting to ${device.name ?: device.address} autoConnect=$autoConnect...")
        gatt = device.connectGatt(context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
        withTimeout(
            if (autoConnect) {
                CameraVendorBleReconnectPolicy.REMEMBERED_DIRECT_CONNECT_TIMEOUT_MS
            } else {
                15_000L
            }
        ) { connected.await() }
        Log.d(TAG, "GATT connected")
    }

    private suspend fun discoverServices(): List<BluetoothGattService> {
        servicesDiscovered = CompletableDeferred()
        gatt!!.discoverServices()
        return withTimeout(15_000) { servicesDiscovered.await() }
    }

    private suspend fun reconnect(device: BluetoothDevice): List<BluetoothGattService> {
        Log.d(TAG, "Reconnecting...")
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        delay(1000)
        connectGatt(device)
        val services = discoverServices()
        prepareDiscoveredServices(services)
        return services
    }

    private suspend fun rediscoverServicesForConfirmation(): List<BluetoothGattService> {
        if (gatt == null) {
            val device = connectedDevice ?: throw Exception("GATT disconnected")
            return reconnect(device)
        }
        observedCharacteristicValues.clear()
        val services = discoverServices()
        prepareDiscoveredServices(services)
        return services
    }

    private suspend fun prepareDiscoveredServices(services: List<BluetoothGattService>) {
        val coordinator = CameraVendorBleHandshakeCoordinator()
        for (svc in services) {
            coordinator.registerServiceForCharacteristicDiscovery(svc.uuid.toString())
            val chars = svc.characteristics.map { it.uuid.short() }
            if (chars.isNotEmpty()) Log.d(TAG, "  ${svc.uuid.short()}: $chars")
            coordinator.completeCharacteristicDiscovery(svc.uuid.toString())
        }
        readHandshakeMetadata(services, coordinator)
        subscribeToNotifiableCharacteristics(services, coordinator)
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
        if (!wifiSSID.isNullOrBlank()) return
        try {
            val raw = readChar(
                CameraVendorBleProfile.DEVICE_NAME_SERVICE, CameraVendorBleProfile.DEVICE_NAME_CHAR
            )
            val name = raw.trimmedUtf8()
            if (name.isNotEmpty()) {
                cameraDeviceName = name
                wifiSSID = name
                Log.d(TAG, "Camera name → SSID: $name")
                return
            }
        } catch (e: Exception) {
            Log.w(TAG, "readCameraName failed: $e")
        }
        cameraDeviceName = device.name
        wifiSSID = device.name
        Log.d(TAG, "Fallback SSID: $wifiSSID")
    }

    private suspend fun refreshReferenceAppNetworkConfig() {
        if (preferredWifiNetwork != null && !wifiSSID.isNullOrBlank() && !wifiPassphrase.isNullOrBlank()) {
            Log.d(TAG, "ReferenceApp WiFi config already available; skip BLE reread")
            return
        }

        val observedSsid = observedCharacteristicValues[CameraVendorBleProfile.CAMERA_WIFI_SSID_CHAR]?.trimmedUtf8()
        val observedPassphrase = observedCharacteristicValues[CameraVendorBleProfile.CAMERA_WIFI_PASSPHRASE_CHAR]?.trimmedUtf8()
        val observedMacAddress = observedCharacteristicValues[CameraVendorBleProfile.CAMERA_WIFI_MAC_ADDRESS_CHAR]
            ?.cameraVendorMacAddressString()
        val ssid = observedSsid ?: runCatching {
            readCharAny(CameraVendorBleProfile.CAMERA_WIFI_SSID_CHAR).trimmedUtf8()
        }.onFailure {
            Log.w(TAG, "ReferenceApp WiFi SSID read failed: $it")
        }.getOrNull()
        val passphrase = observedPassphrase ?: runCatching {
            readCharAny(CameraVendorBleProfile.CAMERA_WIFI_PASSPHRASE_CHAR).trimmedUtf8()
        }.onFailure {
            Log.w(TAG, "ReferenceApp WiFi passphrase read failed: $it")
        }.getOrNull()
        val macAddress = observedMacAddress ?: runCatching {
            readCharAny(CameraVendorBleProfile.CAMERA_WIFI_MAC_ADDRESS_CHAR).cameraVendorMacAddressString()
        }.onFailure {
            Log.w(TAG, "ReferenceApp WiFi MAC read failed: $it")
        }.getOrNull()

        if (!ssid.isNullOrBlank() && !passphrase.isNullOrBlank()) {
            preferredWifiNetwork = CameraVendorWifiNetworkConfigurationPolicy.referenceAppConfiguration(
                ssid = ssid,
                passphrase = passphrase,
                macAddress = macAddress,
            )
            wifiSSID = ssid
            wifiPassphrase = passphrase
            Log.d(
                TAG,
                "ReferenceApp WiFi config: ssid=$ssid hidden=false " +
                    "passphraseLength=${passphrase.length} " +
                    "hasBssid=${preferredWifiNetwork?.bssid != null}",
            )
        } else {
            Log.d(
                TAG,
                "ReferenceApp WiFi config unavailable: ssid=${!ssid.isNullOrBlank()} passphrase=${!passphrase.isNullOrBlank()}",
            )
        }
    }

    private suspend fun performReferenceAppTransferActivation(
        preferCompressedDownloads: Boolean = CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads(),
    ) {
        writeReferenceAppTransferActivationRequest(preferCompressedDownloads)
        waitForTransferWifiReady()
    }

    private suspend fun writeReferenceAppTransferActivationRequest(
        preferCompressedDownloads: Boolean = CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads(),
    ) {
        val required = listOf(
            CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_CHAR,
            CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_EX_CHAR,
            CameraVendorBleProfile.IMAGE_RESIZE_SETTING_CHAR,
            CameraVendorBleProfile.LAUNCH_REQUEST_CHAR,
            CameraVendorBleProfile.AP_STATE_CHAR,
        )
        if (required.any { findCharacteristic(it) == null }) {
            throw Exception("相机还没有进入可传图的配对服务，已停止连接 WiFi。请确认相机处于配对/传图确认界面后重试")
        }

        observedCharacteristicValues.remove(CameraVendorBleProfile.AP_STATE_CHAR)
        observedCharacteristicValues.remove(CameraVendorBleProfile.TRANSFER_STATE_CHAR)
        Log.d(TAG, "=== ReferenceApp official import-image activation ===")
        Log.d(TAG, "Transfer resize mode=${if (preferCompressedDownloads) "compressed" else "original"}")
        DiagnosticLog.append(context, TAG, "ReferenceApp activation started mode=${if (preferCompressedDownloads) "compressed" else "original"}")
        writeCharAny(CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_CHAR, byteArrayOf(0x00))
        DiagnosticLog.append(context, TAG, "ReferenceApp activation write ImageTransferSetting=00")
        writeCharAny(CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_EX_CHAR, byteArrayOf(0x01))
        DiagnosticLog.append(context, TAG, "ReferenceApp activation write ImageTransferSettingEx=01")
        writeCharAny(
            CameraVendorBleProfile.IMAGE_RESIZE_SETTING_CHAR,
            CameraVendorBleTransferActivationPolicy.resizePayload(preferCompressedDownloads),
        )
        DiagnosticLog.append(
            context,
            TAG,
            "ReferenceApp activation write ImageResizeSetting=${if (preferCompressedDownloads) "01" else "00"}",
        )
        delay(500)
        writeCharAny(CameraVendorBleProfile.LAUNCH_REQUEST_CHAR, byteArrayOf(0x03, 0x00))
        DiagnosticLog.append(context, TAG, "ReferenceApp activation write FunctionLaunchRequest=0300")
    }

    private suspend fun waitForReferenceAppApReady() {
        val startedMs = SystemClock.elapsedRealtime()
        var attempt = 0
        var lastState: ByteArray? = null
        while (SystemClock.elapsedRealtime() - startedMs < CameraVendorBleTransferActivationPolicy.AP_READY_TIMEOUT_MS) {
            attempt += 1
            val state = observedCharacteristicValues[CameraVendorBleProfile.AP_STATE_CHAR]
                ?: runCatching {
                    readCharAny(
                        CameraVendorBleProfile.AP_STATE_CHAR,
                        timeoutMs = CameraVendorBleTransferActivationPolicy.AP_READY_READ_TIMEOUT_MS,
                    )
                }.getOrNull()
            if (state != null) lastState = state
            if (state != null && state.size >= 2) {
                val value = CameraVendorBleTransferActivationPolicy.apStateHex(state)
                val elapsedMs = SystemClock.elapsedRealtime() - startedMs
                Log.d(TAG, "AP state attempt=$attempt: $value elapsedMs=$elapsedMs")
                DiagnosticLog.append(
                    context,
                    TAG,
                    "ReferenceApp AP state attempt=$attempt value=$value elapsedMs=$elapsedMs",
                )
                if (CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(state)) {
                    DiagnosticLog.append(context, TAG, "ReferenceApp AP ready elapsedMs=$elapsedMs")
                    return
                }
            }
            delay(CameraVendorBleTransferActivationPolicy.AP_READY_POLL_INTERVAL_MS)
        }
        if (CameraVendorBleTransferActivationPolicy.shouldProceedToWifiAfterReadyWait(lastState)) {
            DiagnosticLog.append(
                context,
                TAG,
                "ReferenceApp AP ready wait ended with launching state; proceeding to WiFi " +
                    "fallbackFromLaunchingState=${CameraVendorBleTransferActivationPolicy.apStateHex(lastState)} " +
                    "timeoutMs=${CameraVendorBleTransferActivationPolicy.AP_READY_TIMEOUT_MS}",
            )
            return
        }
        DiagnosticLog.append(
            context,
            TAG,
            "ReferenceApp AP ready timed out lastState=${CameraVendorBleTransferActivationPolicy.apStateHex(lastState)} " +
                "timeoutMs=${CameraVendorBleTransferActivationPolicy.AP_READY_TIMEOUT_MS}",
        )
        throw Exception("相机尚未确认配对或 WiFi 未启动，已停止连接 WiFi。请等相机显示配对成功后再继续")
    }

    private fun ByteArray.cameraVendorMacAddressString(): String {
        val text = trimmedUtf8()
        if (CameraVendorWifiNetworkConfigurationPolicy.normalizeBssid(text) != null) return text
        return joinToString("") { "%02x".format(it) }
    }

    private suspend fun writeChar(serviceUuid: UUID, charUuid: UUID, value: ByteArray) {
        val g = gatt ?: throw Exception("GATT disconnected")
        val svc = g.getService(serviceUuid) ?: throw Exception("Service missing")
        val ch = svc.getCharacteristic(charUuid) ?: throw Exception("Char missing")

        writeResult = CompletableDeferred()
        val wt = if (CameraVendorBleWriteTypePolicy.shouldWriteWithResponse(
                ch.uuid,
                ch.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0,
            )
        )
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        writeCharacteristic(g, ch, value, wt)
        withTimeout(10_000) { writeResult.await() }
    }

    private suspend fun writeCharAny(charUuid: UUID, value: ByteArray) {
        val ch = findCharacteristic(charUuid) ?: throw Exception("Char missing: $charUuid")
        writeResult = CompletableDeferred()
        val wt = if (CameraVendorBleWriteTypePolicy.shouldWriteWithResponse(
                ch.uuid,
                ch.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0,
            )
        )
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        writeCharacteristic(gatt!!, ch, value, wt)
        withTimeout(10_000) { writeResult.await() }
    }

    private suspend fun readChar(
        serviceUuid: UUID,
        charUuid: UUID,
        timeoutMs: Long = 8_000L,
    ): ByteArray {
        val g = gatt ?: throw Exception("GATT disconnected")
        val svc = g.getService(serviceUuid) ?: throw Exception("Service missing")
        val ch = svc.getCharacteristic(charUuid) ?: throw Exception("Char missing")

        readResult = CompletableDeferred()
        g.readCharacteristic(ch)
        return withTimeout(timeoutMs) { readResult.await() }
    }

    private suspend fun readCharAny(charUuid: UUID, timeoutMs: Long = 8_000L): ByteArray {
        val ch = findCharacteristic(charUuid) ?: throw Exception("Char missing: $charUuid")
        readResult = CompletableDeferred()
        gatt!!.readCharacteristic(ch)
        return withTimeout(timeoutMs) { readResult.await() }
    }

    private suspend fun readHandshakeMetadata(
        services: List<BluetoothGattService>,
        coordinator: CameraVendorBleHandshakeCoordinator,
    ) {
        val metadataChars = setOf(
            CameraVendorBleProfile.DEVICE_NAME_CHAR,
            CameraVendorBleProfile.MODEL_NUMBER_CHAR,
            CameraVendorBleProfile.SERIAL_NUMBER_CHAR,
            CameraVendorBleProfile.FIRMWARE_VERSION_CHAR,
            CameraVendorBleProfile.MANUFACTURER_NAME_CHAR,
        )
        val targets = services.flatMap { it.characteristics }.filter { it.uuid in metadataChars }
        for (characteristic in targets) {
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0) continue
            coordinator.registerMetadataRead(characteristic.uuid.toString())
            runCatching {
                val value = readChar(characteristic.service.uuid, characteristic.uuid)
                if (characteristic.uuid == CameraVendorBleProfile.DEVICE_NAME_CHAR) {
                    val name = value.trimmedUtf8()
                    if (name.isNotBlank()) {
                        cameraDeviceName = name
                        wifiSSID = name
                    }
                } else if (characteristic.uuid == CameraVendorBleProfile.SERIAL_NUMBER_CHAR) {
                    val serial = value.trimmedUtf8()
                    if (serial.isNotBlank()) cameraSerialNumber = serial
                }
                Log.d(TAG, "Metadata ${characteristic.uuid.short()}: ${value.trimmedUtf8()}")
            }.onFailure {
                Log.w(TAG, "Metadata read failed ${characteristic.uuid.short()}: $it")
            }
            coordinator.completeMetadataRead(characteristic.uuid.toString())
        }
    }

    private suspend fun subscribeToNotifiableCharacteristics(
        services: List<BluetoothGattService>,
        coordinator: CameraVendorBleHandshakeCoordinator,
    ) {
        val targets = services.flatMap { it.characteristics }
            .filter {
                CameraVendorBleNotificationSubscriptionPolicy.shouldSubscribeDuringHandshake(it.uuid) &&
                    (
                        it.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 ||
                            it.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
                        )
            }

        for (characteristic in targets) {
            subscribeToCharacteristic(characteristic, coordinator)
        }
    }

    private suspend fun subscribeToCharacteristic(
        characteristic: BluetoothGattCharacteristic,
        coordinator: CameraVendorBleHandshakeCoordinator,
    ) {
        val g = gatt ?: throw Exception("GATT disconnected")
        val cccd = characteristic.getDescriptor(CLIENT_CHARACTERISTIC_CONFIG) ?: return
        coordinator.registerNotificationSubscription(characteristic.uuid.toString())
        if (!g.setCharacteristicNotification(characteristic, true)) {
            throw Exception("Notify start failed: ${characteristic.uuid}")
        }

        val value =
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) {
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            } else {
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            }
        descriptorWriteResult = CompletableDeferred()
        writeDescriptor(g, cccd, value)
        runCatching {
            withTimeout(8_000) { descriptorWriteResult.await() }
        }.onFailure {
            Log.w(TAG, "Notify subscription failed ${characteristic.uuid.short()}: $it")
        }
        coordinator.completeNotificationSubscription(characteristic.uuid.toString())
    }

    private fun findCharacteristic(charUuid: UUID): BluetoothGattCharacteristic? {
        val services = gatt?.services ?: return null
        for (service in services) {
            service.getCharacteristic(charUuid)?.let { return it }
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun writeCharacteristic(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
        writeType: Int,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val result = gatt.writeCharacteristic(characteristic, value, writeType)
            if (result != BluetoothStatusCodes.SUCCESS) {
                writeResult.completeExceptionally(Exception("Write start failed: $result"))
            }
            return
        }
        characteristic.writeType = writeType
        characteristic.value = value
        if (!gatt.writeCharacteristic(characteristic)) {
            writeResult.completeExceptionally(Exception("Write start failed"))
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(
        gatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
        value: ByteArray,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val result = gatt.writeDescriptor(descriptor, value)
            if (result != BluetoothStatusCodes.SUCCESS) {
                descriptorWriteResult.completeExceptionally(Exception("Descriptor write start failed: $result"))
            }
            return
        }
        descriptor.value = value
        if (!gatt.writeDescriptor(descriptor)) {
            descriptorWriteResult.completeExceptionally(Exception("Descriptor write start failed"))
        }
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

    private fun appName(): ByteArray {
        val connectedDeviceName = CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName()
        Log.d(TAG, "Connected device name payload: $connectedDeviceName")
        return connectedDeviceName.toByteArray(Charsets.UTF_8)
    }
    private fun ByteArray.trimmedUtf8(): String =
        copyOfRange(0, indexOf(0).takeIf { it >= 0 } ?: size)
            .toString(Charsets.UTF_8)
            .trim()
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun UUID.short() = toString().take(8)

    companion object {
        private val CLIENT_CHARACTERISTIC_CONFIG =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
