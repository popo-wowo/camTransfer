package com.camtransfer.service.connection

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.camtransfer.ble.CameraVendorBleHandshake
import com.camtransfer.ble.CameraVendorBleHandshakeMode
import com.camtransfer.ble.CameraVendorBleReconnectPolicy
import com.camtransfer.ble.CameraVendorBleReconnectStage
import com.camtransfer.ble.CameraVendorBleScanner
import com.camtransfer.ble.CameraVendorBleSessionReusePolicy
import com.camtransfer.ble.CameraVendorBleTransferActivationPolicy
import com.camtransfer.protocol.CameraVendorPtpConnectionStartupPolicy
import com.camtransfer.protocol.PtpConnection
import com.camtransfer.service.CameraBluetoothPermissionPolicy
import com.camtransfer.service.CameraConnectionCancellationPolicy
import com.camtransfer.service.CameraVendorBleEndpointPolicy
import com.camtransfer.service.CameraVendorCameraIdentityPolicy
import com.camtransfer.service.CameraVendorOfficialCameraOpenAdapter
import com.camtransfer.service.CameraVendorOfficialGalleryConnectionPolicy
import com.camtransfer.service.CameraVendorPairedCameraRecord
import com.camtransfer.service.CameraVendorPairedCameraStore
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.wifi.CameraVendorWifiJoinPolicy
import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration
import com.camtransfer.wifi.WifiConnector
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout

private const val TAG = "CameraGalleryConnectionCoordinator"

class CameraGalleryConnectionCoordinator(
    private val context: Context,
    private val scanner: CameraVendorBleScanner,
    private val wifiConnector: WifiConnector,
    private val pairingStore: CameraVendorPairedCameraStore,
    private val connection: PtpConnection,
    private val rememberedPairing: () -> CameraVendorPairedCameraRecord?,
    private val currentHandshake: () -> CameraVendorBleHandshake?,
    private val currentHandshakeAgeMs: () -> Long,
    private val publishHandshake: (CameraVendorBleHandshake) -> Unit,
    private val clearHandshake: () -> Unit,
    private val rememberedRecordFor: (CameraVendorBleHandshake) -> CameraVendorPairedCameraRecord,
    private val preferCompressedDownloads: () -> Boolean,
    private val ptpClientName: () -> String,
) {
    suspend fun refreshRememberedCameraBleOnlineStatus(onStatus: (String) -> Unit = {}): Boolean {
        val remembered = rememberedPairing() ?: return false
        val startedAtMs = SystemClock.elapsedRealtime()
        DiagnosticLog.append(context, TAG, "Remembered BLE online refresh started cameraId=${remembered.cameraId}")
        onStatus("正在更新相机连接状态: ${remembered.deviceName}")

        val existingHandshake = currentHandshake()
        return runCatching {
            val refreshedHandshake = reusableRememberedHandshake(existingHandshake, remembered)
                ?: reconnectRememberedCamera(onStatus)
            val elapsedMs = SystemClock.elapsedRealtime() - startedAtMs
            DiagnosticLog.append(context, TAG, "Remembered BLE online refresh confirmed elapsedMs=$elapsedMs")
            if (existingHandshake == null) {
                DiagnosticLog.append(context, TAG, "Keeping startup BLE online refresh handshake for gallery flow")
            }
            onStatus("相机在线: ${remembered.deviceName}")
            true
        }.getOrElse { error ->
            if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
            val elapsedMs = SystemClock.elapsedRealtime() - startedAtMs
            DiagnosticLog.append(context, TAG, "Remembered BLE online refresh failed elapsedMs=$elapsedMs", error)
            onStatus("已配对 ${remembered.deviceName}")
            false
        }
    }

    suspend fun connectToGallery(onStatus: (String) -> Unit = {}) {
        var connectedHandshake: CameraVendorBleHandshake? = null
        var wifiConfigurations: List<CameraVendorWifiNetworkConfiguration> = emptyList()
        val preferCompressedDownloads = preferCompressedDownloads()
        CameraGalleryConnectionService(
            onStepStarted = { step ->
                DiagnosticLog.append(context, TAG, "Official gallery step started step=$step")
            },
            onStepConfirmed = { step, elapsedMs ->
                DiagnosticLog.append(context, TAG, "Official gallery step confirmed step=$step elapsedMs=$elapsedMs")
            },
        ).connect(
            reconnectPairedBle = ReconnectPairedBleStep {
                val remembered = rememberedPairing()
                val existingHandshake = currentHandshake()
                connectedHandshake = reusableRememberedHandshake(existingHandshake, remembered) ?: runCatching {
                    reconnectRememberedCamera(onStatus)
                }.getOrElse { reconnectError ->
                    if (CameraConnectionCancellationPolicy.shouldPropagate(reconnectError)) throw reconnectError
                    Log.w(TAG, "BLE remembered reconnect failed; not attempting WiFi before camera transfer activation", reconnectError)
                    throw IllegalStateException(
                        "无法唤醒相机进入传图模式。请确认相机蓝牙已开启，然后重新点进入相机相册；不会在未唤醒相机时直接连接 WiFi。",
                        reconnectError,
                    )
                }
            },
            transferAuthorization = TransferAuthorizationStep {
                val hs = connectedHandshake ?: throw IllegalStateException("请先完成已配对相机 BLE 重连")
                onStatus("正在确认相机允许这台手机传图")
                val officialWifiConfiguration = hs.refreshReferenceAppWifiConfiguration()
                DiagnosticLog.append(context, TAG, "Gallery transfer authorization confirmed from validated BLE handshake")
                wifiConfigurations = CameraVendorOfficialGalleryConnectionPolicy.officialWifiConfigurations(officialWifiConfiguration)
            },
            activateCameraWifi = ActivateCameraWifiStep {
                val hs = connectedHandshake ?: throw IllegalStateException("请先完成已配对相机 BLE 重连")
                onStatus("正在让相机打开自己的 Wi-Fi")
                DiagnosticLog.append(
                    context,
                    TAG,
                    "Transfer size mode=${if (preferCompressedDownloads) "compressed" else "original"}",
                )
                hs.writeTransferActivationRequest(preferCompressedDownloads)
            },
            waitCameraWifiReady = WaitCameraWifiReadyStep {
                val hs = connectedHandshake ?: throw IllegalStateException("请先完成已配对相机 BLE 重连")
                onStatus("正在等待相机确认 Wi-Fi 已准备好")
                hs.waitForTransferWifiReady()
                hs.disconnectForWifiHandoff()
                delay(CameraVendorBleTransferActivationPolicy.BLUETOOTH_RELEASE_DELAY_MS)
            },
            joinCameraWifi = JoinCameraWifiStep {
                joinCameraWifi(wifiConfigurations, onStatus)
            },
            connectPtp = ConnectPtpStep {
                connectPtpWithRetry(onStatus, confirmGalleryMode = false)
            },
            confirmGalleryMode = ConfirmGalleryModeStep {
                onStatus("正在确认相机已经进入相册模式")
                connection.confirmCameraVendorGalleryMode()
            },
            loadGallery = LoadGalleryStep {
                onStatus("正在读取相机照片数量")
                connection.loadCameraVendorGalleryObjectHandles()
            },
        )

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

        DiagnosticLog.append(
            context,
            TAG,
            "WiFi candidates count=${wifiConfigurations.size} hidden=${wifiConfigurations.count { it.isHidden }}",
        )

        val connected = wifiConfigurations.withIndex().firstOrNull { (index, configuration) ->
            var joined = false
            val maxJoinAttempts = CameraVendorWifiJoinPolicy.AUTO_JOIN_ATTEMPTS_PER_EXACT_NETWORK
            for (joinAttempt in 1..maxJoinAttempts) {
                onStatus(
                    com.camtransfer.service.CameraWifiJoinStatusPolicy.waitingForWifiJoin(
                        ssid = configuration.ssid,
                        attempt = index + 1,
                        total = wifiConfigurations.size,
                    )
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
                            "WiFi connect failed attempt=${index + 1} joinAttempt=$joinAttempt/$maxJoinAttempts " +
                                "hidden=${configuration.isHidden} hasBssid=${configuration.bssid != null}",
                            error,
                        )
                        false
                    },
                )
                if (joined) break
                if (joinAttempt < maxJoinAttempts) {
                    val delayMs = CameraVendorWifiJoinPolicy.retryDelayMs(joinAttempt)
                    DiagnosticLog.append(
                        context,
                        TAG,
                        "WiFi retry cooldown delayMs=$delayMs afterJoinAttempt=$joinAttempt " +
                            "hasBssid=${configuration.bssid != null}",
                    )
                    delay(delayMs)
                }
            }
            joined
        }

        val configuration = connected?.value ?: firstConfiguration
        if (connected == null) {
            val attempted = wifiConfigurations.joinToString {
                "${it.ssid}${if (it.isHidden) "(隐藏)" else ""}${if (it.bssid != null) "(精确BSSID)" else ""}"
            }
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

    suspend fun connectWifiAndPtp(
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

    private suspend fun connectPtpWithRetry(
        onStatus: (String) -> Unit,
        confirmGalleryMode: Boolean = true,
    ) {
        val ptpClientName = ptpClientName()
        DiagnosticLog.append(context, TAG, "PTP legacyInitFriendlyName=$ptpClientName")
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
                    onInitPacket = { label, socketLocalIp, clientIp, packet ->
                        DiagnosticLog.append(
                            context,
                            TAG,
                            "PTP INIT packet label=$label socketLocalIp=$socketLocalIp clientIp=$clientIp bytes=${packet.size} hex=${packet.hex()}",
                        )
                    },
                )
            },
        )
    }

    private fun ByteArray.hex(): String =
        joinToString("") { "%02x".format(it) }

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
                            connectRememberedCameraByAddress(address, remembered)
                        }.onSuccess {
                            DiagnosticLog.append(context, TAG, "Remembered camera direct BLE connect succeeded")
                            return it
                        }.onFailure { error ->
                            if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
                            DiagnosticLog.append(context, TAG, "Remembered camera direct BLE connect failed", error)
                        }
                    }
                }
                CameraVendorBleReconnectStage.OfficialReconnectScan -> {
                    runCatching {
                        onStatus("正在按原厂方式查找已配对相机: ${remembered.deviceName}")
                        connectRememberedCameraByOfficialReconnectScan(remembered)
                    }.onSuccess {
                        DiagnosticLog.append(context, TAG, "Remembered camera official reconnect scan succeeded")
                        return it
                    }.onFailure { error ->
                        if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
                        DiagnosticLog.append(context, TAG, "Remembered camera official reconnect scan failed", error)
                        clearHandshake()
                    }
                }
            }
        }

        throw IllegalStateException("无法连接已配对相机，请确认相机蓝牙已开启并停留在可传图/配对连接界面后重试")
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

    @SuppressLint("MissingPermission")
    private suspend fun connectRememberedCameraByAddress(
        address: String,
        remembered: CameraVendorPairedCameraRecord,
    ): CameraVendorBleHandshake {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val device = manager.adapter.getRemoteDevice(address)
        val hs = CameraVendorBleHandshake(context)
        try {
            hs.performHandshake(
                device,
                autoConnect = true,
                mode = CameraVendorBleHandshakeMode.RememberedGallery,
            )
            ensureRememberedCameraIdentity(hs, remembered)
            publishHandshake(hs)
            return hs
        } catch (error: Throwable) {
            hs.disconnect()
            throw error
        }
    }

    private suspend fun connectRememberedCameraByOfficialReconnectScan(
        remembered: CameraVendorPairedCameraRecord,
    ): CameraVendorBleHandshake {
        val scanResult = withTimeout(CameraVendorBleReconnectPolicy.REMEMBERED_RECONNECT_SCAN_TIMEOUT_MS) {
            scanner.scanAll().first { result ->
                rememberedScanResultMatches(result, remembered)
            }
        }
        val hs = CameraVendorBleHandshake(context)
        try {
            hs.performHandshake(scanResult, mode = CameraVendorBleHandshakeMode.RememberedGallery)
            ensureRememberedCameraIdentity(hs, remembered)
            publishHandshake(hs)
            return hs
        } catch (error: Throwable) {
            hs.disconnect()
            throw error
        }
    }

    private fun rememberedScanResultMatches(
        result: ScanResult,
        remembered: CameraVendorPairedCameraRecord,
    ): Boolean {
        val name = result.device.name ?: result.scanRecord?.deviceName ?: ""
        val address = result.device.address
        return address == remembered.bluetoothAddress ||
            name.isNotBlank() && name == remembered.deviceName
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
            ageMs = currentHandshakeAgeMs(),
        )
        if (canReuse) {
            DiagnosticLog.append(context, TAG, "Reusing validated remembered BLE handshake")
            return hs
        }
        DiagnosticLog.append(context, TAG, "Cached remembered BLE handshake rejected; validated BLE reconnect required")
        hs.disconnect()
        clearHandshake()
        return null
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
        DiagnosticLog.append(context, TAG, "Remembered BLE address candidates count=${candidates.size}")
        return candidates.map { it.address }
    }
}
