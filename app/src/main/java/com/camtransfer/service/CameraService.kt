package com.camtransfer.service

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.camtransfer.ble.CameraVendorCameraPairingConfirmationPolicy
import com.camtransfer.ble.CameraVendorBleHandshake
import com.camtransfer.ble.CameraVendorBleHandshakeMode
import com.camtransfer.ble.CameraVendorBleScanner
import com.camtransfer.ble.CameraVendorBleReconnectPolicy
import com.camtransfer.ble.CameraVendorBleReconnectStage
import com.camtransfer.ble.CameraVendorBleSessionReusePolicy
import com.camtransfer.ble.CameraVendorBleTransferActivationPolicy
import com.camtransfer.ble.CameraVendorHandshakeIdentityPolicy
import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.CameraVendorGalleryDiscoveryPolicy
import com.camtransfer.protocol.CameraVendorPtpIdentityPolicy
import com.camtransfer.protocol.CameraVendorPtpConnectionStartupPolicy
import com.camtransfer.protocol.PtpCommands
import com.camtransfer.protocol.PtpConnection
import com.camtransfer.protocol.PtpObjectFormat
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
    private var handshakeUpdatedAtMs: Long = 0L
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
            cameraId = CameraVendorCameraIdentityPolicy.cameraId(
                serialNumber = "",
                deviceName = bondedCamera.name,
                bluetoothAddress = bondedCamera.address,
            ),
        )
    }

    fun pairedCameras(): List<CameraVendorPairedCameraRecord> =
        pairingStore.loadAll().ifEmpty {
            rememberedPairing()?.let { listOf(it) }.orEmpty()
        }

    fun selectedCameraId(): String? =
        rememberedPairing()?.cameraId

    fun selectPairedCamera(cameraId: String) {
        pairingStore.select(cameraId)
        clearHandshake()
    }

    suspend fun connectToCamera(onStatus: (String) -> Unit = {}) {
        pairWithCamera(onStatus)
        confirmPairing(onStatus)
        connectPairedCameraToGallery(onStatus)
    }

    suspend fun connectExistingCameraWifiToGallery(onStatus: (String) -> Unit = {}): Boolean {
        onStatus("正在检测已连接的相机 WiFi/PTP...")
        return runCatching {
            connection.connect(clientName = cameraVendorPtpClientName())
            onStatus("已连接")
            Log.d(TAG, "Existing camera PTP connection established")
            DiagnosticLog.append(context, TAG, "Existing camera PTP connection established")
            true
        }.getOrElse { error ->
            if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
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
        try {
            hs.performHandshake(scanResult)
            publishHandshake(hs)
        } catch (error: Throwable) {
            hs.disconnect()
            throw error
        }
        DiagnosticLog.append(context, TAG, "BLE handshake completed")
        onStatus(CameraVendorCameraPairingConfirmationPolicy.WAITING_FOR_PHONE_CONFIRMATION_STATUS)
    }

    suspend fun confirmPairing(onStatus: (String) -> Unit = {}) {
        val hs = handshake ?: throw IllegalStateException("请先完成蓝牙配对")
        if (!hs.canCompletePhonePairingConfirmation()) {
            throw IllegalStateException("相机端还没有完成识别号 ACK，不能确认配对")
        }

        onStatus("正在确认手机蓝牙配对已完成")
        if (!hs.waitForSystemBondSettled()) {
            throw IllegalStateException("手机系统蓝牙配对还没有完成，请先确认系统配对弹窗和相机屏幕提示")
        }
        onStatus("正在向相机确认配对结果")
        hs.confirmCameraPairingSucceeded()
        DiagnosticLog.append(context, TAG, "Camera pairing confirmed")
        pairingStore.save(
            rememberedRecordFor(hs)
        )
        onStatus("配对成功")
    }

    suspend fun connectPairedCameraToGallery(onStatus: (String) -> Unit = {}) {
        val adapter = CameraVendorOfficialGalleryConnectionAdapter(
            onStepStarted = { step ->
                DiagnosticLog.append(context, TAG, "Official gallery step started step=$step")
            },
            onStepConfirmed = { step ->
                DiagnosticLog.append(context, TAG, "Official gallery step confirmed step=$step")
            },
        )
        val remembered = rememberedPairing()
        val existingHandshake = handshake
        val hs = adapter.confirmStep(CameraConnectionStep.ReconnectPairedBle) {
            reusableRememberedHandshake(existingHandshake, remembered) ?: runCatching {
                reconnectRememberedCamera(onStatus)
            }.getOrElse { reconnectError ->
                if (CameraConnectionCancellationPolicy.shouldPropagate(reconnectError)) throw reconnectError
                Log.w(TAG, "BLE remembered reconnect failed; not attempting WiFi before camera transfer activation", reconnectError)
                throw IllegalStateException(
                    "无法唤醒相机进入传图模式。请确认相机蓝牙已开启，然后重新点进入相机相册；不会在未唤醒相机时直接连接 WiFi。",
                    reconnectError,
                )
            }
        }

        val wifiConfigurations = adapter.confirmStep(CameraConnectionStep.TransferAuthorization) {
            onStatus("正在确认相机允许这台手机传图")
            val officialWifiConfiguration = hs.refreshReferenceAppWifiConfiguration()
            if (officialWifiConfiguration != null) {
                saveRememberedHandshake(hs)
            }
            hs.confirmCameraPairingSucceeded()
            DiagnosticLog.append(context, TAG, "Gallery transfer authorization replay confirmed")
            listOfNotNull(officialWifiConfiguration)
                .ifEmpty { remembered?.wifiConfigurations.orEmpty() }
                .ifEmpty {
                    throw IllegalStateException("相机没有返回官方 Wi-Fi 名称和密码，已停止进入相册")
                }
        }

        val preferCompressedDownloads = preferCompressedDownloads()
        adapter.confirmStep(CameraConnectionStep.ActivateCameraWifi) {
            onStatus("正在让相机打开自己的 Wi-Fi")
            DiagnosticLog.append(
                context,
                TAG,
                "Transfer size mode=${if (preferCompressedDownloads) "compressed" else "original"}",
            )
            hs.writeTransferActivationRequest(preferCompressedDownloads)
        }
        adapter.confirmStep(CameraConnectionStep.WaitCameraWifiReady) {
            onStatus("正在等待相机确认 Wi-Fi 已准备好")
            hs.waitForTransferWifiReady()
        }
        hs.disconnectForWifiHandoff()
        delay(CameraVendorBleTransferActivationPolicy.BLUETOOTH_RELEASE_DELAY_MS)

        adapter.confirmStep(CameraConnectionStep.JoinCameraWifi) {
            joinCameraWifi(wifiConfigurations, onStatus)
        }
        adapter.confirmStep(CameraConnectionStep.ConnectPtp) {
            connectPtpWithRetry(onStatus, confirmGalleryMode = false)
        }
        adapter.confirmStep(CameraConnectionStep.ConfirmGalleryMode) {
            onStatus("正在确认相机已经进入相册模式")
            connection.confirmCameraVendorGalleryMode()
        }
        adapter.confirmStep(CameraConnectionStep.LoadGallery) {
            onStatus("正在读取相机照片数量")
            connection.loadCameraVendorGalleryObjectHandles()
        }

        onStatus("已连接")
        Log.d(TAG, "Full connection established")
        DiagnosticLog.append(context, TAG, "Full connection established")
    }

    suspend fun retryCameraWifiToGallery(onStatus: (String) -> Unit = {}) {
        if (CameraVendorWifiJoinPolicy.SHOULD_PROBE_EXISTING_PTP_BEFORE_WIFI_REQUEST) {
            onStatus("正在确认手机是否已经手动连上相机 Wi-Fi")
            DiagnosticLog.append(context, TAG, "Probing existing PTP before retrying WiFi request")
            if (connectExistingCameraWifiToGallery(onStatus)) return
        }
        val wifiConfigurations = handshake?.referenceAppWifiConfigurations().orEmpty()
            .ifEmpty { pairingStore.load()?.wifiConfigurations.orEmpty() }
        DiagnosticLog.append(context, TAG, "Retrying camera WiFi/PTP without BLE activation")
        connectWifiAndPtp(wifiConfigurations, onStatus)
    }

    private suspend fun connectWifiAndPtp(
        wifiConfigurations: List<CameraVendorWifiNetworkConfiguration>,
        onStatus: (String) -> Unit,
    ) {
        joinCameraWifi(wifiConfigurations, onStatus)
        onStatus("手机已连到相机 Wi-Fi，正在打开相机 PTP 通信会话")
        connectPtpWithRetry(onStatus)

        onStatus("已连接")
        Log.d(TAG, "Full connection established")
        DiagnosticLog.append(context, TAG, "Full connection established")
    }

    private suspend fun joinCameraWifi(
        wifiConfigurations: List<CameraVendorWifiNetworkConfiguration>,
        onStatus: (String) -> Unit,
    ): CameraVendorWifiNetworkConfiguration {
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
            var joined = false
            for (joinAttempt in 1..CameraVendorWifiJoinPolicy.AUTO_JOIN_ATTEMPTS_PER_EXACT_NETWORK) {
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
                    "WiFi connect attempt ${index + 1}/${wifiConfigurations.size} " +
                        "joinAttempt=$joinAttempt/${CameraVendorWifiJoinPolicy.AUTO_JOIN_ATTEMPTS_PER_EXACT_NETWORK} " +
                        "hidden=${configuration.isHidden}",
                )
                joined = runCatching {
                    wifiConnector.connect(
                        configuration,
                        timeoutMs = CameraVendorWifiJoinPolicy.AUTO_JOIN_TIMEOUT_MS,
                    )
                }.fold(
                    onSuccess = { true },
                    onFailure = { error ->
                        if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
                        lastError = error
                        DiagnosticLog.append(
                            context,
                            TAG,
                            "WiFi connect failed attempt=${index + 1} " +
                                "joinAttempt=$joinAttempt hidden=${configuration.isHidden}",
                            error,
                        )
                        false
                    },
                )
                if (joined) break
                if (joinAttempt < CameraVendorWifiJoinPolicy.AUTO_JOIN_ATTEMPTS_PER_EXACT_NETWORK) {
                    val delayMs = CameraVendorWifiJoinPolicy.retryDelayMs(joinAttempt)
                    onStatus("手机系统还没切到相机 Wi-Fi，继续等待并自动重试")
                    DiagnosticLog.append(
                        context,
                        TAG,
                        "WiFi retry cooldown delayMs=$delayMs afterJoinAttempt=$joinAttempt",
                    )
                    delay(delayMs)
                }
            }
            joined
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
        return configuration
    }

    private suspend fun connectPtpWithRetry(
        onStatus: (String) -> Unit,
        confirmGalleryMode: Boolean = true,
    ) {
        val ptpClientName = cameraVendorPtpClientName()
        DiagnosticLog.append(
            context,
            TAG,
            "PTP legacyInitFriendlyName=$ptpClientName",
        )
        CameraVendorOfficialCameraOpenAdapter().open(
            onAttempt = { attempt, total, _ ->
                onStatus("正在建立 PTP 连接... ($attempt/$total)")
            },
            onFailure = { attempt, total, error ->
                connection.disconnect()
                Log.w(TAG, "PTP official cameraOpen failed ($attempt/$total): $error")
                DiagnosticLog.append(context, TAG, "PTP official cameraOpen failed attempt=$attempt", error)
            },
            onWaitingForStartup = {
                onStatus("等待相机 PTP 服务就绪...")
            },
            onWaitingForRetry = { _, delayMs ->
                onStatus("PTP 暂未就绪，${delayMs / 1000.0}s 后重试")
            },
            openOnce = { timeoutMs ->
                val socketFactory = wifiConnector.connectedNetwork?.socketFactory
                DiagnosticLog.append(context, TAG, "PTP official cameraOpen hasNetworkSocketFactory=${socketFactory != null}")
                connection.connect(
                    socketFactory = socketFactory,
                    clientName = ptpClientName,
                    connectTimeoutMs = timeoutMs.toInt(),
                    initReadTimeoutMs = CameraVendorPtpConnectionStartupPolicy.INIT_ACK_READ_TIMEOUT_MS.toInt(),
                    commandReadTimeoutMs = CameraVendorPtpConnectionStartupPolicy.COMMAND_READ_TIMEOUT_MS.toInt(),
                    confirmGalleryMode = confirmGalleryMode,
                )
            },
        )
    }

    private fun cameraVendorPtpClientName(): String =
        CameraVendorPtpIdentityPolicy.legacyInitFriendlyName(
            CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName()
        )

    private suspend fun reconnectRememberedCamera(onStatus: (String) -> Unit): CameraVendorBleHandshake {
        val remembered = rememberedPairing() ?: throw IllegalStateException("请先完成蓝牙配对")
        val addressCandidates = rememberedBluetoothAddressCandidates(remembered)
        val stages = CameraVendorBleReconnectPolicy.reconnectStages(
            hasRememberedBluetoothAddress = addressCandidates.isNotEmpty(),
            hasStableCameraIdentity = remembered.cameraId.contains("_"),
        )
        DiagnosticLog.append(context, TAG, "Remembered BLE reconnect stages=$stages")

        for (stage in stages) {
            when (stage) {
                CameraVendorBleReconnectStage.DirectAddress -> {
                    for (address in addressCandidates) {
                        runCatching {
                            onStatus("正在直连已配对相机: ${remembered.deviceName}")
                            connectRememberedCameraByAddress(address)
                        }.onSuccess {
                            DiagnosticLog.append(context, TAG, "Remembered camera direct BLE connect succeeded")
                            return it
                        }.onFailure { error ->
                            if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
                            DiagnosticLog.append(context, TAG, "Remembered camera direct BLE connect failed", error)
                            Log.w(TAG, "Remembered camera direct BLE connect failed address=$address: $error")
                        }
                    }
                }
                CameraVendorBleReconnectStage.FastScan -> {
                    runCatching {
                        onStatus("正在用蓝牙查找已配对相机: ${remembered.deviceName}")
                        val scanResult: ScanResult = withTimeout(CameraVendorBleReconnectPolicy.REMEMBERED_FAST_SCAN_TIMEOUT_MS) {
                            scanner.scanAll().first { result ->
                                rememberedScanResultMatches(result, remembered)
                            }
                        }
                        val hs = CameraVendorBleHandshake(context)
                        try {
                            hs.performHandshake(scanResult, mode = CameraVendorBleHandshakeMode.RememberedGallery)
                            publishHandshake(hs)
                            saveRememberedHandshake(hs)
                            DiagnosticLog.append(context, TAG, "Remembered camera fast scan reconnect succeeded")
                            return hs
                        } catch (error: Throwable) {
                            hs.disconnect()
                            throw error
                        }
                    }.onFailure { error ->
                        if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
                        DiagnosticLog.append(context, TAG, "Remembered camera fast scan reconnect skipped", error)
                        Log.w(TAG, "Remembered camera fast scan reconnect failed: $error")
                        clearHandshake()
                    }
                }
                CameraVendorBleReconnectStage.ScanFallback -> {
                    return reconnectRememberedCameraByScanFallback(remembered, onStatus)
                }
            }
        }

        throw IllegalStateException("无法连接已配对相机，请确认相机蓝牙已开启并停留在可传图/配对连接界面后重试")
    }

    private suspend fun reconnectRememberedCameraByScanFallback(
        remembered: CameraVendorPairedCameraRecord,
        onStatus: (String) -> Unit,
    ): CameraVendorBleHandshake {
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
                try {
                    hs.performHandshake(scanResult, mode = CameraVendorBleHandshakeMode.RememberedGallery)
                    publishHandshake(hs)
                    saveRememberedHandshake(hs)
                    return hs
                } catch (error: Throwable) {
                    hs.disconnect()
                    throw error
                }
            } catch (error: Throwable) {
                if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
                lastError = error
                Log.w(TAG, "Remembered camera reconnect failed ($attempt/${CameraVendorBleReconnectPolicy.MAX_REMEMBERED_RECONNECT_ATTEMPTS}): $error")
                clearHandshake()
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

    private fun ensureRememberedCameraIdentity(
        hs: CameraVendorBleHandshake,
        remembered: CameraVendorPairedCameraRecord,
    ) {
        val candidateCameraId = CameraVendorCameraIdentityPolicy.cameraId(
            serialNumber = hs.cameraSerial(),
            deviceName = hs.cameraName(),
            bluetoothAddress = hs.bluetoothAddress(),
            wifiSsid = hs.referenceAppWifiConfigurations().firstOrNull()?.ssid,
        )
        val matches = CameraVendorCameraIdentityPolicy.matches(
            remembered = remembered,
            candidateCameraId = candidateCameraId,
            candidateSerialNumber = hs.cameraSerial(),
            candidateDeviceName = hs.cameraName(),
            candidateBluetoothAddress = hs.bluetoothAddress(),
        )
        if (!matches) {
            DiagnosticLog.append(context, TAG, "Remembered camera identity mismatch")
            throw IllegalStateException("已连接的相机不是当前选中的已配对相机，请重新配对后再进入相册")
        }
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
        try {
            hs.performHandshake(
                device,
                autoConnect = true,
                mode = CameraVendorBleHandshakeMode.RememberedGallery,
            )
            publishHandshake(hs)
            saveRememberedHandshake(hs)
            return hs
        } catch (error: Throwable) {
            hs.disconnect()
            throw error
        }
    }

    private fun reusableRememberedHandshake(
        existingHandshake: CameraVendorBleHandshake?,
        remembered: CameraVendorPairedCameraRecord?,
    ): CameraVendorBleHandshake? {
        val hs = existingHandshake ?: return null
        val matches = remembered?.let {
            runCatching {
                ensureRememberedCameraIdentity(hs, it)
                true
            }.getOrElse { error ->
                DiagnosticLog.append(context, TAG, "Cached remembered BLE handshake rejected: identity mismatch", error)
                false
            }
        } ?: false
        val canReuse = CameraVendorBleSessionReusePolicy.canReuseForTransferActivation(
            hasLiveGatt = hs.hasLiveGattConnection(),
            hasRequiredTransferCharacteristics = hs.hasRequiredTransferActivationCharacteristics(),
            rememberedCameraMatches = matches,
            hasCompletedCameraAck = hs.hasCompletedCameraPairingAck(),
            ageMs = SystemClock.elapsedRealtime() - handshakeUpdatedAtMs,
        )
        if (canReuse) {
            DiagnosticLog.append(context, TAG, "Reusing validated remembered BLE handshake")
            return hs
        }
        DiagnosticLog.append(context, TAG, "Cached remembered BLE handshake rejected; direct reconnect required")
        hs.disconnect()
        clearHandshake()
        return null
    }

    private fun publishHandshake(hs: CameraVendorBleHandshake) {
        handshake = hs
        handshakeUpdatedAtMs = SystemClock.elapsedRealtime()
    }

    private fun clearHandshake() {
        handshake = null
        handshakeUpdatedAtMs = 0L
    }

    private fun saveRememberedHandshake(hs: CameraVendorBleHandshake) {
        pairingStore.save(rememberedRecordFor(hs))
    }

    private fun rememberedRecordFor(hs: CameraVendorBleHandshake): CameraVendorPairedCameraRecord {
        val wifiConfigurations = hs.referenceAppWifiConfigurations()
        return CameraVendorPairedCameraRecord(
            deviceName = hs.cameraName(),
            serialNumber = hs.cameraSerial(),
            wifiConfigurations = wifiConfigurations,
            bluetoothAddress = hs.bluetoothAddress(),
            cameraId = CameraVendorCameraIdentityPolicy.cameraId(
                serialNumber = hs.cameraSerial(),
                deviceName = hs.cameraName(),
                bluetoothAddress = hs.bluetoothAddress(),
                wifiSsid = wifiConfigurations.firstOrNull()?.ssid,
            ),
            lastConnectedAtMillis = System.currentTimeMillis(),
        )
    }

    @SuppressLint("MissingPermission")
    private fun rememberedBluetoothAddressCandidates(
        remembered: CameraVendorPairedCameraRecord,
    ): List<String> {
        val systemBonds = if (CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            manager.adapter.bondedDevices
                ?.map { device ->
                    CameraVendorBleEndpointPolicy.SystemBond(
                        name = device.name.orEmpty(),
                        address = device.address.orEmpty(),
                    )
                }
                .orEmpty()
        } else {
            DiagnosticLog.append(context, TAG, "Skipped system BLE endpoint candidates: missing BLUETOOTH_CONNECT")
            emptyList()
        }
        val candidates = CameraVendorBleEndpointPolicy.identityVerifiedCandidates(
            remembered = remembered,
            systemBonds = systemBonds,
        )
        Log.d(
            TAG,
            "Remembered BLE endpoint candidates for ${remembered.cameraId}: ${
                candidates.joinToString { "${it.address}/${it.source}" }
            }",
        )
        DiagnosticLog.append(context, TAG, "Remembered BLE address candidates count=${candidates.size}")
        return candidates.map { it.address }
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

    override suspend fun fastInitialFiles(): List<CameraFile> {
        if (connection.cameraVendorSpecifiedObjectHandles.isEmpty()) {
            runCatching { connection.loadCameraVendorGalleryObjectHandles() }
                .onFailure {
                    DiagnosticLog.append(context, TAG, "Fast gallery handle initialization failed", it)
                }
        }
        val handles = CameraVendorGalleryDiscoveryPolicy.initialPlaceholderHandles(
            connection.cameraVendorSpecifiedObjectHandles
        )
        if (handles.isEmpty()) return emptyList()
        DiagnosticLog.append(context, TAG, "Fast gallery placeholders count=${handles.size}")
        return handles.map { handle -> CameraFile(placeholderObjectInfo(handle)) }
    }

    override suspend fun getThumbnail(handle: Int): ByteArray {
        DiagnosticLog.append(context, TAG, "Get thumbnail handle=$handle")
        return commands.getThumb(handle)
    }

    override suspend fun resolveFile(handle: Int): CameraFile? {
        DiagnosticLog.append(context, TAG, "Resolve file metadata handle=$handle")
        return runCatching { CameraFile(commands.getObjectInfo(handle)) }
            .onSuccess { file ->
                DiagnosticLog.append(
                    context,
                    TAG,
                    "Resolved file metadata handle=$handle filename=${file.info.filename} expected=${file.info.compressedSize}",
                )
            }
            .onFailure { error ->
                DiagnosticLog.append(context, TAG, "Resolve file metadata failed handle=$handle", error)
            }
            .getOrNull()
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

    private fun placeholderObjectInfo(handle: Int): ObjectInfo = ObjectInfo(
        handle = handle,
        storageId = 0,
        format = PtpObjectFormat.JPEG,
        compressedSize = 0,
        thumbFormat = 0,
        thumbCompressedSize = 0,
        thumbPixWidth = 0,
        thumbPixHeight = 0,
        imagePixWidth = 0,
        imagePixHeight = 0,
        parentObject = 0,
        filename = "0x%08X.JPG".format(handle),
        captureDate = "",
    )

    override suspend fun disconnect() {
        DiagnosticLog.append(context, TAG, "Disconnecting services")
        connection.disconnect()
        wifiConnector.disconnect()
        handshake?.disconnect()
        clearHandshake()
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
