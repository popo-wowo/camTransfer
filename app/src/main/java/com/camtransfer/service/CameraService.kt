package com.camtransfer.service

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanResult
import android.content.Context
import android.util.Log
import com.camtransfer.ble.CameraVendorCameraPairingConfirmationPolicy
import com.camtransfer.ble.CameraVendorBleHandshake
import com.camtransfer.ble.CameraVendorBleScanner
import com.camtransfer.ble.CameraVendorBleReconnectPolicy
import com.camtransfer.ble.CameraVendorBleTransferActivationPolicy
import com.camtransfer.model.CameraFile
import com.camtransfer.protocol.CameraVendorPtpConnectionStartupPolicy
import com.camtransfer.protocol.PtpCommands
import com.camtransfer.protocol.PtpConnection
import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration
import com.camtransfer.wifi.CameraVendorWifiJoinPolicy
import com.camtransfer.wifi.WifiConnector
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

private const val TAG = "CameraService"

class CameraService(override val context: Context) : CameraFileSource {

    private val scanner = CameraVendorBleScanner(context)
    private var handshake: CameraVendorBleHandshake? = null
    private val wifiConnector = WifiConnector(context)
    private val pairingStore = CameraVendorPairedCameraStore(context)
    private val transferPrefs = context.getSharedPreferences("camtransfer.transfer", Context.MODE_PRIVATE)
    val connection = PtpConnection()
    val commands by lazy { PtpCommands(connection, context) }

    @SuppressLint("MissingPermission")
    fun rememberedPairing(): CameraVendorPairedCameraRecord? {
        pairingStore.load()?.let { return it }
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            DiagnosticLog.append(context, TAG, "Skipped system BLE bonds fallback: missing BLUETOOTH_CONNECT")
            return null
        }
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bondedCamera = manager.adapter.bondedDevices
            ?.firstOrNull { device ->
                val name = device.name.orEmpty().uppercase()
                val isCamera = name.startsWith("X-") || name.startsWith("FUJIFILM") || name.startsWith("GFX")
                isCamera && CameraVendorPairingForgetPolicy.canUseSystemBondAsRememberedPairing(
                    bluetoothAddress = device.address,
                    deletedBluetoothAddresses = pairingStore.deletedBluetoothAddresses(),
                )
            }
            ?: return null
        return CameraVendorPairedCameraRecord(
            deviceName = bondedCamera.name ?: "CAMERA_VENDOR",
            serialNumber = "",
            wifiConfigurations = emptyList(),
            bluetoothAddress = bondedCamera.address,
        )
    }

    suspend fun connectToCamera(onStatus: (String) -> Unit = {}) {
        pairWithCamera(onStatus)
        confirmPairing(onStatus)
        connectPairedCameraToGallery(onStatus)
    }

    suspend fun connectExistingCameraWifiToGallery(onStatus: (String) -> Unit = {}): Boolean {
        onStatus("正在检测已连接的相机 WiFi/PTP...")
        return runCatching {
            connection.connect()
            onStatus("已连接")
            Log.d(TAG, "Existing camera PTP connection established")
            DiagnosticLog.append(context, TAG, "Existing camera PTP connection established")
            true
        }.getOrElse { error ->
            connection.disconnect()
            Log.d(TAG, "Existing camera PTP probe failed: ${error.message}")
            DiagnosticLog.append(context, TAG, "Existing camera PTP probe failed", error)
            false
        }
    }

    suspend fun pairWithCamera(onStatus: (String) -> Unit = {}) {
        DiagnosticLog.append(context, TAG, "Pair with camera started")
        onStatus(CameraPairingGuidance.SCANNING_STATUS)
        val scanResult: ScanResult = withTimeout(15_000) {
            scanner.scanAll().first()
        }
        Log.d(TAG, "Found camera: ${scanResult.device.name ?: scanResult.device.address}")
        DiagnosticLog.append(context, TAG, "Found camera")
        ensureNoStaleSystemBondBeforeFreshPairing(scanResult.device)

        onStatus(CameraPairingGuidance.BLE_PAIRING_STATUS)
        val hs = CameraVendorBleHandshake(context)
        handshake = hs
        hs.performHandshake(scanResult)
        DiagnosticLog.append(context, TAG, "BLE handshake completed")
        onStatus(CameraVendorCameraPairingConfirmationPolicy.WAITING_FOR_PHONE_CONFIRMATION_STATUS)
    }

    suspend fun confirmPairing(onStatus: (String) -> Unit = {}) {
        val hs = handshake ?: throw IllegalStateException("请先完成蓝牙配对")
        if (!hs.canCompletePhonePairingConfirmation()) {
            throw IllegalStateException("相机端还没有完成识别号 ACK，不能确认配对")
        }

        onStatus("正在向相机确认配对结果")
        hs.confirmCameraPairingSucceeded()
        DiagnosticLog.append(context, TAG, "Camera pairing confirmed")
        pairingStore.save(
            CameraVendorPairedCameraRecord(
                deviceName = hs.cameraName(),
                serialNumber = hs.cameraSerial(),
                wifiConfigurations = hs.wifiConfigurations(),
                bluetoothAddress = hs.bluetoothAddress(),
            )
        )
        onStatus("配对成功")
    }

    suspend fun connectPairedCameraToGallery(onStatus: (String) -> Unit = {}) {
        val remembered = pairingStore.load()
        val hs = handshake ?: runCatching {
            reconnectRememberedCamera(onStatus)
        }.getOrElse { reconnectError ->
            Log.w(TAG, "BLE remembered reconnect failed; not attempting WiFi before camera transfer activation", reconnectError)
            throw IllegalStateException(
                "无法唤醒相机进入传图模式。请确认相机蓝牙已开启，然后重新点进入相机相册；不会在未唤醒相机时直接连接 WiFi。",
                reconnectError,
            )
        }

        onStatus("正在用蓝牙唤醒相机的传图模式")
        val wifiConfigurations = hs.refreshWifiConfigurations().ifEmpty {
            remembered?.wifiConfigurations.orEmpty()
        }

        onStatus("正在确认相机允许这台手机传图")
        hs.confirmCameraPairingSucceeded()

        val preferCompressedDownloads = preferCompressedDownloads()
        onStatus("正在让相机打开自己的 Wi-Fi")
        DiagnosticLog.append(
            context,
            TAG,
            "Transfer size mode=${if (preferCompressedDownloads) "compressed" else "original"}",
        )
        hs.prepareTransferActivation(preferCompressedDownloads)
        hs.disconnectForWifiHandoff()
        delay(CameraVendorBleTransferActivationPolicy.BLUETOOTH_RELEASE_DELAY_MS)

        connectWifiAndPtp(wifiConfigurations, onStatus)
    }

    private suspend fun connectWifiAndPtp(
        wifiConfigurations: List<CameraVendorWifiNetworkConfiguration>,
        onStatus: (String) -> Unit,
    ) {
        if (wifiConfigurations.isEmpty()) {
            throw IllegalStateException("没有可用的相机 WiFi 名称候选")
        }
        val firstConfiguration = wifiConfigurations.first()
        var lastError: Throwable? = null

        Log.d(
            TAG,
            "WiFi candidates: ${wifiConfigurations.joinToString { "${it.ssid}(hidden=${it.isHidden})" }}",
        )
        DiagnosticLog.append(
            context,
            TAG,
            "WiFi candidates count=${wifiConfigurations.size} hidden=${wifiConfigurations.count { it.isHidden }}",
        )

        val connected = wifiConfigurations.withIndex().firstOrNull { (index, configuration) ->
            onStatus(
                CameraWifiJoinStatusPolicy.waitingForWifiJoin(
                    ssid = configuration.ssid,
                    attempt = index + 1,
                    total = wifiConfigurations.size,
                )
            )
            DiagnosticLog.append(
                context,
                TAG,
                "WiFi connect attempt ${index + 1}/${wifiConfigurations.size} hidden=${configuration.isHidden}",
            )
            runCatching {
                wifiConnector.connect(
                    configuration,
                    timeoutMs = CameraVendorWifiJoinPolicy.AUTO_JOIN_TIMEOUT_MS,
                )
            }.fold(
                onSuccess = { true },
                onFailure = { error ->
                    lastError = error
                    DiagnosticLog.append(
                        context,
                        TAG,
                        "WiFi connect failed attempt=${index + 1} hidden=${configuration.isHidden}",
                        error,
                    )
                    false
                },
            )
        }

        val configuration = connected?.value ?: firstConfiguration
        if (connected == null) {
            val attempted = wifiConfigurations.joinToString { "${it.ssid}${if (it.isHidden) "(隐藏)" else ""}" }
            throw IllegalStateException(
                "手机没有自动加入相机 Wi-Fi，请手动加入后重试。\n" +
                    "已尝试: $attempted\n" +
                    "SSID: ${configuration.ssid}\n" +
                    "密码: ${configuration.passphrase}" +
                    if (configuration.isHidden) {
                        "\n这是隐藏网络，请在 Wi-Fi 的“其他网络”里手动输入。这个 Wi-Fi 不能上网是正常的。"
                    } else {
                        "\n这个 Wi-Fi 不能上网是正常的。"
                    },
                lastError,
            )
        }

        onStatus("手机已连到相机 Wi-Fi，正在等待相机打开相册通道")
        delay(CameraVendorPtpConnectionStartupPolicy.STARTUP_DELAY_MS)
        connectPtpWithRetry(onStatus)

        onStatus("已连接")
        Log.d(TAG, "Full connection established")
        DiagnosticLog.append(context, TAG, "Full connection established")
    }

    private suspend fun connectPtpWithRetry(onStatus: (String) -> Unit) {
        var lastError: Throwable? = null
        for (attempt in 1..CameraVendorPtpConnectionStartupPolicy.MAX_CONNECT_ATTEMPTS) {
            try {
                onStatus("正在打开相机相册通道 ($attempt/${CameraVendorPtpConnectionStartupPolicy.MAX_CONNECT_ATTEMPTS})")
                connection.connect()
                return
            } catch (error: Throwable) {
                lastError = error
                connection.disconnect()
                Log.w(TAG, "PTP connection failed ($attempt/${CameraVendorPtpConnectionStartupPolicy.MAX_CONNECT_ATTEMPTS}): $error")
                DiagnosticLog.append(context, TAG, "PTP connection failed attempt=$attempt", error)
                if (attempt == CameraVendorPtpConnectionStartupPolicy.MAX_CONNECT_ATTEMPTS) break
                val delayMs = CameraVendorPtpConnectionStartupPolicy.retryDelayMs(attempt)
                onStatus("相机相册通道还没响应，${delayMs / 1000.0}s 后再试一次")
                delay(delayMs)
            }
        }
        throw IllegalStateException("相册通道连接失败，请确认相机仍停留在传图/相册模式后重试", lastError)
    }

    private suspend fun reconnectRememberedCamera(onStatus: (String) -> Unit): CameraVendorBleHandshake {
        val remembered = rememberedPairing() ?: throw IllegalStateException("请先完成蓝牙配对")
        runCatching {
            onStatus("正在用蓝牙查找已配对相机: ${remembered.deviceName}")
            val scanResult: ScanResult = withTimeout(CameraVendorBleReconnectPolicy.REMEMBERED_FAST_SCAN_TIMEOUT_MS) {
                scanner.scanAll().first { result ->
                    rememberedScanResultMatches(result, remembered)
                }
            }
            val hs = CameraVendorBleHandshake(context)
            handshake = hs
            hs.performHandshake(scanResult)
            saveRememberedHandshake(hs)
            DiagnosticLog.append(context, TAG, "Remembered camera fast scan reconnect succeeded")
            return hs
        }.onFailure { error ->
            DiagnosticLog.append(context, TAG, "Remembered camera fast scan reconnect skipped", error)
            Log.w(TAG, "Remembered camera fast scan reconnect failed: $error")
            handshake?.disconnect()
            handshake = null
        }

        for (address in rememberedBluetoothAddressCandidates(remembered)) {
            runCatching {
                onStatus("正在直连已配对相机: ${remembered.deviceName}")
                connectRememberedCameraByAddress(address)
            }.onSuccess { return it }
                .onFailure { Log.w(TAG, "Remembered camera direct BLE connect failed address=$address: $it") }
        }
        var lastError: Throwable? = null
        for (attempt in 1..CameraVendorBleReconnectPolicy.MAX_REMEMBERED_RECONNECT_ATTEMPTS) {
            onStatus("正在用蓝牙唤醒已配对相机: ${remembered.deviceName} ($attempt/${CameraVendorBleReconnectPolicy.MAX_REMEMBERED_RECONNECT_ATTEMPTS})")
            try {
                val scanResult: ScanResult = withTimeout(CameraVendorBleReconnectPolicy.REMEMBERED_SCAN_TIMEOUT_MS) {
                    scanner.scanAll().first { result ->
                        rememberedScanResultMatches(result, remembered)
                    }
                }
                val hs = CameraVendorBleHandshake(context)
                handshake = hs
                hs.performHandshake(scanResult)
                saveRememberedHandshake(hs)
                return hs
            } catch (error: Throwable) {
                lastError = error
                Log.w(TAG, "Remembered camera reconnect failed ($attempt/${CameraVendorBleReconnectPolicy.MAX_REMEMBERED_RECONNECT_ATTEMPTS}): $error")
                handshake?.disconnect()
                handshake = null
                if (error is TimeoutCancellationException) break
                if (attempt == CameraVendorBleReconnectPolicy.MAX_REMEMBERED_RECONNECT_ATTEMPTS) break
                delay(CameraVendorBleReconnectPolicy.retryDelayMs(attempt))
            }
        }
        throw IllegalStateException(
            "无法连接已配对相机，请确认相机蓝牙已开启并停留在可传图/配对连接界面后重试",
            lastError,
        )
    }

    private fun rememberedScanResultMatches(
        result: ScanResult,
        remembered: CameraVendorPairedCameraRecord,
    ): Boolean {
        val name = result.device.name ?: result.scanRecord?.deviceName ?: ""
        val address = result.device.address
        return address == remembered.bluetoothAddress ||
            name.isNotBlank() && (
                name == remembered.deviceName ||
                    name.contains(remembered.deviceName, ignoreCase = true) ||
                    remembered.deviceName.contains(name, ignoreCase = true)
                )
    }

    @SuppressLint("MissingPermission")
    private suspend fun connectRememberedCameraByAddress(address: String): CameraVendorBleHandshake {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val device = manager.adapter.getRemoteDevice(address)
        val hs = CameraVendorBleHandshake(context)
        handshake = hs
        hs.performHandshake(device, autoConnect = true)
        saveRememberedHandshake(hs)
        return hs
    }

    private fun saveRememberedHandshake(hs: CameraVendorBleHandshake) {
        pairingStore.save(
            CameraVendorPairedCameraRecord(
                deviceName = hs.cameraName(),
                serialNumber = hs.cameraSerial(),
                wifiConfigurations = hs.wifiConfigurations(),
                bluetoothAddress = hs.bluetoothAddress(),
            )
        )
    }

    @SuppressLint("MissingPermission")
    private fun rememberedBluetoothAddressCandidates(
        remembered: CameraVendorPairedCameraRecord,
    ): List<String> {
        val candidates = linkedSetOf<String>()
        if (CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            manager.adapter.bondedDevices
                ?.filter { device ->
                    val name = device.name.orEmpty()
                    name.isNotBlank() && (
                        name == remembered.deviceName ||
                            name.contains(remembered.deviceName, ignoreCase = true) ||
                            remembered.deviceName.contains(name, ignoreCase = true)
                        )
                }
                ?.forEach { candidates.add(it.address) }
        } else {
            DiagnosticLog.append(context, TAG, "Skipped system BLE address candidates: missing BLUETOOTH_CONNECT")
        }
        remembered.bluetoothAddress?.let { candidates.add(it) }
        Log.d(TAG, "Remembered BLE address candidates for ${remembered.deviceName}: $candidates")
        DiagnosticLog.append(context, TAG, "Remembered BLE address candidates count=${candidates.size}")
        return candidates.toList()
    }

    override suspend fun listFiles(): List<CameraFile> {
        DiagnosticLog.append(context, TAG, "Reading gallery object infos")
        val files = commands.galleryObjectInfos()
            .filterNot { it.isFolder || it.isVideo }
            .map { CameraFile(it) }
            .sortedWith(compareByDescending<CameraFile> { it.info.captureDate }.thenByDescending { it.info.handle })
        DiagnosticLog.append(context, TAG, "Gallery object infos visible=${files.size}")
        return files
    }

    override suspend fun getThumbnail(handle: Int): ByteArray {
        DiagnosticLog.append(context, TAG, "Get thumbnail handle=$handle")
        return commands.getThumb(handle)
    }

    override suspend fun getFile(handle: Int): ByteArray {
        DiagnosticLog.append(context, TAG, "Get original file handle=$handle")
        val expectedSize = runCatching { commands.getObjectInfo(handle).compressedSize }.getOrNull()
        val data = commands.getObject(handle, expectedSize)
        DiagnosticLog.append(context, TAG, "Original file loaded handle=$handle bytes=${data.size} expected=$expectedSize")
        return data
    }

    fun getFileStream(handle: Int) = commands.getObjectStream(handle)

    fun preferCompressedDownloads(): Boolean =
        if (transferPrefs.contains(TRANSFER_COMPRESSION_KEY)) {
            transferPrefs.getBoolean(
                TRANSFER_COMPRESSION_KEY,
                CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads(),
            )
        } else {
            CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads()
        }

    fun setPreferCompressedDownloads(preferCompressedDownloads: Boolean) {
        transferPrefs.edit().putBoolean(TRANSFER_COMPRESSION_KEY, preferCompressedDownloads).apply()
        DiagnosticLog.append(
            context,
            TAG,
            "Transfer size preference=${if (preferCompressedDownloads) "compressed" else "original"}",
        )
    }

    override suspend fun disconnect() {
        DiagnosticLog.append(context, TAG, "Disconnecting services")
        connection.disconnect()
        wifiConnector.disconnect()
        handshake?.disconnect()
        handshake = null
    }

    suspend fun forgetPairing() {
        val remembered = rememberedPairing()
        val bluetoothAddresses = remembered
            ?.let { rememberedBluetoothAddressCandidates(it) }
            .orEmpty()
        disconnect()
        pairingStore.rememberDeletedBluetoothAddresses(bluetoothAddresses)
        removeSystemBluetoothBonds(bluetoothAddresses)
        pairingStore.clear()
    }

    @SuppressLint("MissingPermission")
    private fun ensureNoStaleSystemBondBeforeFreshPairing(device: BluetoothDevice) {
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            DiagnosticLog.append(context, TAG, "Skipped stale BLE bond check: missing BLUETOOTH_CONNECT")
            return
        }
        if (!CameraVendorPairingForgetPolicy.shouldPromptSystemBondRemovalBeforeFreshPairing(device.bondState)) {
            return
        }
        val message = CameraVendorPairingForgetPolicy.systemBondRemovalMessage(device.name)
        DiagnosticLog.append(context, TAG, "Fresh pairing blocked by existing system BLE bond")
        throw IllegalStateException(message)
    }

    @SuppressLint("MissingPermission")
    private fun removeSystemBluetoothBonds(bluetoothAddresses: List<String>) {
        val normalizedAddresses = bluetoothAddresses
            .map(CameraVendorPairingForgetPolicy::normalizeBluetoothAddress)
            .toSet()
        if (normalizedAddresses.isEmpty()) return
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            DiagnosticLog.append(context, TAG, "Skipped system BLE bond removal: missing BLUETOOTH_CONNECT")
            return
        }

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        manager.adapter.bondedDevices
            ?.filter { device ->
                CameraVendorPairingForgetPolicy.normalizeBluetoothAddress(device.address) in normalizedAddresses
            }
            ?.forEach { device ->
                runCatching { removeSystemBluetoothBond(device) }
                    .onSuccess { removed ->
                        DiagnosticLog.append(context, TAG, "System BLE bond remove requested success=$removed")
                    }
                    .onFailure { error ->
                        DiagnosticLog.append(context, TAG, "System BLE bond remove failed", error)
                    }
            }
    }

    private fun removeSystemBluetoothBond(device: BluetoothDevice): Boolean {
        val method = device.javaClass.getMethod("removeBond")
        return method.invoke(device) as? Boolean ?: false
    }

    private companion object {
        const val TRANSFER_COMPRESSION_KEY = "downloadCompressionEnabled"
    }
}
