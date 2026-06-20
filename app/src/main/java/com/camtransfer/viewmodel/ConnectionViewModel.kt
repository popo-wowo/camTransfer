package com.camtransfer.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.ble.CameraVendorBleTransferActivationPolicy
import com.camtransfer.service.CameraConnectionFailure
import com.camtransfer.service.CameraConnectionIssue
import com.camtransfer.service.CameraConnectionIssueClassifier
import com.camtransfer.service.CameraConnectionMode
import com.camtransfer.service.CameraConnectionStep
import com.camtransfer.service.CameraService
import com.camtransfer.service.CameraVendorPairedCameraRecord
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

private const val ONLINE_REFRESH_GALLERY_HANDOFF_WAIT_MS = 4_000L

enum class ConnectionState {
    IDLE,
    SCANNING,
    CONNECTING_BLE,
    WAITING_CAMERA_CONFIRMATION,
    PAIRED,
    CONNECTING_WIFI,
    CONNECTING_PTP,
    CONNECTED,
    ERROR,
}

class ConnectionViewModel(app: Application) : AndroidViewModel(app) {

    private val appContext = app.applicationContext
    val cameraService = CameraService(app.applicationContext)

    private val _state = MutableStateFlow(ConnectionState.IDLE)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _statusText = MutableStateFlow("")
    val statusText: StateFlow<String> = _statusText.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _connectionIssue = MutableStateFlow<CameraConnectionIssue?>(null)
    val connectionIssue: StateFlow<CameraConnectionIssue?> = _connectionIssue.asStateFlow()

    private val _activeStep = MutableStateFlow<CameraConnectionStep?>(null)
    val activeStep: StateFlow<CameraConnectionStep?> = _activeStep.asStateFlow()

    private val _connectionMode = MutableStateFlow(CameraConnectionMode.AUTO)
    val connectionMode: StateFlow<CameraConnectionMode> = _connectionMode.asStateFlow()

    private val _galleryConnectionEvent = MutableStateFlow(0L)
    val galleryConnectionEvent: StateFlow<Long> = _galleryConnectionEvent.asStateFlow()

    private val _preferCompressedDownloads = MutableStateFlow(cameraService.preferCompressedDownloads())
    val preferCompressedDownloads: StateFlow<Boolean> = _preferCompressedDownloads.asStateFlow()

    private val _pairedCameras = MutableStateFlow<List<CameraVendorPairedCameraRecord>>(emptyList())
    val pairedCameras: StateFlow<List<CameraVendorPairedCameraRecord>> = _pairedCameras.asStateFlow()

    private val _selectedCameraId = MutableStateFlow<String?>(null)
    val selectedCameraId: StateFlow<String?> = _selectedCameraId.asStateFlow()

    private var connectionJob: Job? = null
    private var onlineRefreshJob: Job? = null

    init {
        DiagnosticLog.append(appContext, "App", "ConnectionViewModel initialized")
        refreshPairedCameras()
        if (publishRegistrationConsistencyIssueIfNeeded()) {
            DiagnosticLog.append(appContext, "Connection", "Registration consistency issue detected at startup")
        } else cameraService.rememberedPairing()?.let { remembered ->
            _state.value = ConnectionState.PAIRED
            _statusText.value = "已配对 ${remembered.deviceName}"
            DiagnosticLog.append(appContext, "Connection", "Remembered pairing exists")
            startPairedCameraOnlineRefresh(remembered.deviceName)
        }
    }

    fun connect() {
        if (_state.value == ConnectionState.CONNECTED ||
            _state.value == ConnectionState.WAITING_CAMERA_CONFIRMATION ||
            _state.value == ConnectionState.PAIRED
        ) return
        _connectionMode.value = CameraConnectionMode.AUTO
        _connectionIssue.value = null
        _error.value = null
        _statusText.value = "正在开始连接相机"
        startPairingFlow()
    }

    fun startGuidedPairing() {
        if (_state.value == ConnectionState.CONNECTED ||
            _state.value == ConnectionState.WAITING_CAMERA_CONFIRMATION ||
            _state.value == ConnectionState.PAIRED
        ) return
        if (publishRegistrationConsistencyIssueIfNeeded()) return
        val issue = CameraConnectionIssue.cameraPairingModeRequired()
        _state.value = CameraConnectionUiPolicy.stateForStep(issue.step)
        _error.value = null
        _connectionIssue.value = issue
        _activeStep.value = issue.step
        _connectionMode.value = CameraConnectionMode.GUIDED
        _statusText.value = issue.detail
        DiagnosticLog.append(
            appContext,
            "ConnectionIssue",
            "mode=${_connectionMode.value} phase=${issue.phase} step=${issue.step} failure=${issue.failure} action=${issue.primaryAction}",
        )
        DiagnosticLog.append(appContext, "Connection", "Pairing mode confirmation required before BLE scan")
    }

    fun confirmCameraPairingModeAndStartScan() {
        if (_state.value == ConnectionState.CONNECTED ||
            _state.value == ConnectionState.WAITING_CAMERA_CONFIRMATION ||
            _state.value == ConnectionState.PAIRED
        ) return
        _connectionMode.value = CameraConnectionMode.GUIDED
        startPairingFlow()
    }

    private fun startPairingFlow() {
        if (publishRegistrationConsistencyIssueIfNeeded()) return
        val entryState = _state.value
        cancelConnectionJob()
        cancelPairedCameraOnlineRefresh()
        _state.value = ConnectionState.SCANNING
        _error.value = null
        _connectionIssue.value = null
        _activeStep.value = CameraConnectionStep.BleScan
        DiagnosticLog.append(appContext, "Connection", "BLE scan started mode=${_connectionMode.value}")
        val hasRememberedPairing = cameraService.rememberedPairing() != null

        connectionJob = viewModelScope.launch {
            var currentStep = CameraConnectionStep.BleScan
            try {
                if (CameraConnectionEntryPolicy.shouldProbeExistingPtpBeforeBle(entryState, hasRememberedPairing)) {
                    currentStep = CameraConnectionStep.ExistingPtpProbe
                    _activeStep.value = currentStep
                    val directPtpConnected = cameraService.connectExistingCameraWifiToGallery { status ->
                        DiagnosticLog.append(appContext, "ConnectionStatus", status)
                        _statusText.value = status
                        _state.value = when {
                            "已连接" in status -> ConnectionState.CONNECTED
                            else -> ConnectionState.CONNECTING_PTP
                        }
                        currentStep = CameraConnectionStep.ExistingPtpProbe
                        _activeStep.value = currentStep
                    }
                    if (directPtpConnected) {
                        _state.value = ConnectionState.CONNECTED
                        _connectionIssue.value = null
                        DiagnosticLog.append(appContext, "Connection", "Connected through existing PTP session")
                        publishGalleryConnectionEvent()
                        return@launch
                    }
                    _state.value = ConnectionState.SCANNING
                }
                cameraService.pairWithCamera { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    _statusText.value = status
                    _state.value = CameraConnectionStatusPolicy.pairingState(status, _state.value)
                    currentStep = CameraConnectionStatusPolicy.pairingStep(status, currentStep)
                    _activeStep.value = currentStep
                }
                _state.value = ConnectionState.WAITING_CAMERA_CONFIRMATION
                _activeStep.value = CameraConnectionStep.PairingConfirmation
                _connectionIssue.value = null
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DiagnosticLog.append(appContext, "Connection", "Connect failed", e)
                publishIssue(currentStep, e)
                _state.value = ConnectionState.ERROR
                _error.value = e.message ?: "连接失败"
            }
        }
    }

    fun confirmCameraPairingSucceeded() {
        if (_state.value != ConnectionState.WAITING_CAMERA_CONFIRMATION) return
        _error.value = null
        _connectionIssue.value = null
        _activeStep.value = CameraConnectionStep.PairingConfirmation
        cancelConnectionJob()
        connectionJob = viewModelScope.launch {
            try {
                cameraService.confirmPairing { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    _statusText.value = status
                    _state.value = when {
                        "配对成功" in status -> ConnectionState.PAIRED
                        else -> ConnectionState.CONNECTING_BLE
                    }
                }
                _state.value = ConnectionState.PAIRED
                _activeStep.value = CameraConnectionStep.SavePairing
                refreshPairedCameras()
                val remembered = cameraService.rememberedPairing()
                _statusText.value = remembered?.let { "已配对 ${it.deviceName}" } ?: "已保存配对"
                _connectionIssue.value = null
                DiagnosticLog.append(appContext, "Connection", "Pairing confirmed")
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DiagnosticLog.append(appContext, "Connection", "Pairing confirmation failed", e)
                publishIssue(CameraConnectionStep.PairingConfirmation, e)
                _state.value = ConnectionState.ERROR
                _error.value = e.message ?: "连接失败"
            }
        }
    }

    fun enterCameraAlbum() {
        enterCameraAlbum(resetBeforeStart = false)
    }

    private fun enterCameraAlbum(resetBeforeStart: Boolean) {
        if (_state.value != ConnectionState.PAIRED) return
        if (publishRegistrationConsistencyIssueIfNeeded()) return
        _error.value = null
        _connectionIssue.value = null
        _activeStep.value = CameraConnectionStep.ReconnectPairedBle
        _state.value = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.ReconnectPairedBle)
        DiagnosticLog.append(appContext, "Connection", "Enter gallery requested resetBeforeStart=$resetBeforeStart")
        cancelConnectionJob()
        connectionJob = viewModelScope.launch {
            var currentStep = CameraConnectionStep.ReconnectPairedBle
            try {
                if (resetBeforeStart) {
                    cancelPairedCameraOnlineRefreshAndWait()
                    cameraService.resetGalleryConnectionBeforeRetry()
                } else {
                    awaitPairedCameraOnlineRefreshBeforeGalleryStart()
                }
                cameraService.connectPairedCameraToGallery { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    _statusText.value = status
                    currentStep = CameraConnectionStatusPolicy.galleryStep(status, currentStep)
                    _activeStep.value = currentStep
                    _state.value = CameraConnectionStatusPolicy.galleryState(status, _state.value)
                }
                _state.value = ConnectionState.CONNECTED
                _activeStep.value = CameraConnectionStep.LoadGallery
                _connectionIssue.value = null
                refreshPairedCameras()
                DiagnosticLog.append(appContext, "Connection", "Gallery connection established")
                publishGalleryConnectionEvent()
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DiagnosticLog.append(appContext, "Connection", "Enter gallery failed", e)
                val issue = publishIssue(currentStep, e)
                _state.value = if (issue.failure == CameraConnectionFailure.PairingRegistrationOutOfSync) {
                    ConnectionState.ERROR
                } else {
                    ConnectionState.PAIRED
                }
                val remembered = cameraService.rememberedPairing()
                _statusText.value = remembered?.let { "已配对 ${it.deviceName}" } ?: "已保存配对"
                _error.value = if (issue.failure == CameraConnectionFailure.PairingRegistrationOutOfSync) {
                    issue.detail
                } else {
                    e.message ?: "进入相册失败"
                }
            }
        }
    }

    fun confirmWifiJoinedAndOpenGallery() {
        _error.value = null
        _connectionIssue.value = null
        _connectionMode.value = CameraConnectionMode.GUIDED
        _activeStep.value = CameraConnectionStep.ConnectPtp
        cancelConnectionJob()
        cancelPairedCameraOnlineRefresh()
        connectionJob = viewModelScope.launch {
            try {
                val directPtpConnected = cameraService.connectExistingCameraWifiToGallery { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    _statusText.value = status
                    _activeStep.value = if ("已连接" in status) {
                        CameraConnectionStep.LoadGallery
                    } else {
                        CameraConnectionStep.ConnectPtp
                    }
                    _state.value = when {
                        "已连接" in status -> ConnectionState.CONNECTED
                        else -> ConnectionState.CONNECTING_PTP
                    }
                }
                if (directPtpConnected) {
                _state.value = ConnectionState.CONNECTED
                _connectionIssue.value = null
                refreshPairedCameras()
                DiagnosticLog.append(appContext, "Connection", "Gallery connection established after manual WiFi")
                    publishGalleryConnectionEvent()
                } else {
                    val issue = CameraConnectionIssue.ptpNotReady()
                    _connectionIssue.value = issue
                    _activeStep.value = issue.step
                    _state.value = ConnectionState.PAIRED
                    _error.value = issue.detail
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DiagnosticLog.append(appContext, "Connection", "Manual WiFi PTP verification failed", e)
                publishIssue(CameraConnectionStep.ConnectPtp, e)
                _state.value = ConnectionState.PAIRED
                _error.value = e.message ?: "相册连接失败"
            }
        }
    }

    private fun retryCameraWifiAndOpenGallery() {
        _error.value = null
        _connectionIssue.value = null
        _activeStep.value = CameraConnectionStep.JoinCameraWifi
        cancelConnectionJob()
        cancelPairedCameraOnlineRefresh()
        connectionJob = viewModelScope.launch {
            var currentStep = CameraConnectionStep.JoinCameraWifi
            try {
                cameraService.retryCameraWifiToGallery { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    _statusText.value = status
                    currentStep = CameraConnectionStatusPolicy.galleryStep(status, currentStep)
                    _activeStep.value = currentStep
                    _state.value = CameraConnectionStatusPolicy.galleryState(status, _state.value)
                }
                _state.value = ConnectionState.CONNECTED
                _activeStep.value = CameraConnectionStep.LoadGallery
                _connectionIssue.value = null
                refreshPairedCameras()
                DiagnosticLog.append(appContext, "Connection", "Gallery connection established after WiFi retry")
                publishGalleryConnectionEvent()
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DiagnosticLog.append(appContext, "Connection", "WiFi retry failed", e)
                publishIssue(currentStep, e)
                _state.value = ConnectionState.PAIRED
                val remembered = cameraService.rememberedPairing()
                _statusText.value = remembered?.let { "已配对 ${it.deviceName}" } ?: "已保存配对"
                _error.value = e.message ?: "相册连接失败"
            }
        }
    }

    fun retryCurrentIssue() {
        when (CameraConnectionRetryPolicy.targetForStep(connectionIssue.value?.step)) {
            CameraConnectionRetryTarget.PairingConfirmation -> confirmCameraPairingSucceeded()
            CameraConnectionRetryTarget.WifiHandoffWithoutBle -> retryCameraWifiAndOpenGallery()
            CameraConnectionRetryTarget.ExistingPtpProbe -> confirmWifiJoinedAndOpenGallery()
            CameraConnectionRetryTarget.PairingScan -> connect()
            CameraConnectionRetryTarget.PairingModeConfirmation -> confirmCameraPairingModeAndStartScan()
            CameraConnectionRetryTarget.GalleryEntryWithBle -> enterCameraAlbum(resetBeforeStart = true)
            CameraConnectionRetryTarget.ResetConnection -> resetConnectionForFreshPairing()
        }
    }

    fun setPreferCompressedDownloads(preferCompressedDownloads: Boolean) {
        cameraService.setPreferCompressedDownloads(preferCompressedDownloads)
        _preferCompressedDownloads.value = preferCompressedDownloads
        _statusText.value = CameraVendorBleTransferActivationPolicy.statusText(preferCompressedDownloads)
    }

    fun disconnect() {
        viewModelScope.launch {
            DiagnosticLog.append(appContext, "Connection", "Disconnect requested")
            cancelConnectionJob()
            cancelPairedCameraOnlineRefreshAndWait()
            cameraService.disconnect()
            refreshPairedCameras()
            _state.value = ConnectionState.IDLE
            cameraService.rememberedPairing()?.let { remembered ->
                _state.value = ConnectionState.PAIRED
                _statusText.value = "已配对 ${remembered.deviceName}"
            } ?: run {
                _statusText.value = ""
            }
            _error.value = null
            _connectionIssue.value = null
            _activeStep.value = null
        }
    }

    fun forgetPairing() {
        resetConnectionForFreshPairing()
    }

    fun resetConnectionForFreshPairing() {
        viewModelScope.launch {
            DiagnosticLog.append(appContext, "Connection", "Reset connection for fresh pairing requested")
            cancelConnectionJob()
            cancelPairedCameraOnlineRefreshAndWait()
            cameraService.resetConnectionForFreshPairing()
            refreshPairedCameras()
            _state.value = ConnectionState.IDLE
            _statusText.value = "已重置连接，请先关闭原厂 App，并在相机和系统蓝牙中删除旧记录后重新配对。"
            _error.value = null
            _connectionIssue.value = null
            _activeStep.value = CameraConnectionStep.CameraPairingMode
        }
    }

    fun selectPairedCamera(cameraId: String) {
        if (_state.value != ConnectionState.PAIRED) return
        cameraService.selectPairedCamera(cameraId)
        refreshPairedCameras()
        val remembered = cameraService.rememberedPairing()
        _statusText.value = remembered?.let { "已配对 ${it.deviceName}" } ?: "已保存配对"
        _error.value = null
        _connectionIssue.value = null
    }

    private fun refreshPairedCameras() {
        val cameras = cameraService.pairedCameras()
        _pairedCameras.value = cameras
        _selectedCameraId.value = cameraService.selectedCameraId()
    }

    private fun startPairedCameraOnlineRefresh(deviceName: String) {
        cancelPairedCameraOnlineRefresh()
        onlineRefreshJob = viewModelScope.launch {
            try {
                val online = cameraService.refreshPairedCameraOnlineStatus { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    if (_state.value == ConnectionState.PAIRED) {
                        _statusText.value = status
                    }
                }
                if (_state.value == ConnectionState.PAIRED && online) {
                    _statusText.value = "相机在线: $deviceName"
                } else if (_state.value == ConnectionState.PAIRED) {
                    _statusText.value = "已保存配对，未连接相机: $deviceName"
                    DiagnosticLog.append(appContext, "Connection", "Startup BLE online refresh did not find camera online")
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DiagnosticLog.append(appContext, "Connection", "Remembered camera online refresh failed", e)
                if (_state.value == ConnectionState.PAIRED) {
                    _statusText.value = "已保存配对，未连接相机: $deviceName"
                    DiagnosticLog.append(appContext, "Connection", "Startup BLE online refresh failed; keeping paired state")
                }
            }
        }
    }

    private fun publishIssue(step: CameraConnectionStep, error: Throwable): CameraConnectionIssue {
        val issue = CameraConnectionIssueClassifier.fromThrowable(step, error)
        _connectionIssue.value = issue
        _activeStep.value = issue.step
        DiagnosticLog.append(
            appContext,
            "ConnectionIssue",
            "mode=${_connectionMode.value} phase=${issue.phase} step=${issue.step} failure=${issue.failure} action=${issue.primaryAction}",
        )
        return issue
    }

    private fun publishRegistrationConsistencyIssueIfNeeded(): Boolean {
        val issue = cameraService.registrationConsistencyIssue() ?: return false
        _connectionIssue.value = issue
        _activeStep.value = issue.step
        _state.value = ConnectionState.ERROR
        _statusText.value = issue.detail
        _error.value = issue.detail
        DiagnosticLog.append(
            appContext,
            "ConnectionIssue",
            "registrationConsistency phase=${issue.phase} step=${issue.step} failure=${issue.failure} action=${issue.primaryAction}",
        )
        return true
    }

    private fun publishGalleryConnectionEvent() {
        _galleryConnectionEvent.value += 1
    }

    private fun cancelConnectionJob() {
        connectionJob?.cancel()
        connectionJob = null
    }

    private fun cancelPairedCameraOnlineRefresh() {
        onlineRefreshJob?.cancel()
        onlineRefreshJob = null
    }

    private suspend fun cancelPairedCameraOnlineRefreshAndWait() {
        onlineRefreshJob?.cancelAndJoin()
        onlineRefreshJob = null
    }

    private suspend fun awaitPairedCameraOnlineRefreshBeforeGalleryStart() {
        val job = onlineRefreshJob ?: return
        if (!job.isActive) {
            onlineRefreshJob = null
            return
        }
        DiagnosticLog.append(
            appContext,
            "Connection",
            "Waiting for startup BLE online refresh before gallery start timeoutMs=$ONLINE_REFRESH_GALLERY_HANDOFF_WAIT_MS",
        )
        val completed = withTimeoutOrNull(ONLINE_REFRESH_GALLERY_HANDOFF_WAIT_MS) {
            job.join()
            true
        } == true
        if (completed) {
            DiagnosticLog.append(appContext, "Connection", "Startup BLE online refresh completed before gallery start")
            onlineRefreshJob = null
        } else {
            DiagnosticLog.append(
                appContext,
                "Connection",
                "Startup BLE online refresh still running before gallery start; cancelling and restarting gallery BLE",
            )
            job.cancelAndJoin()
            onlineRefreshJob = null
        }
    }

    override fun onCleared() {
        super.onCleared()
        cancelConnectionJob()
        cancelPairedCameraOnlineRefresh()
    }
}

enum class CameraConnectionRetryTarget {
    PairingConfirmation,
    WifiHandoffWithoutBle,
    ExistingPtpProbe,
    PairingScan,
    PairingModeConfirmation,
    GalleryEntryWithBle,
    ResetConnection,
}

internal object CameraConnectionRetryPolicy {
    fun targetForStep(step: CameraConnectionStep?): CameraConnectionRetryTarget =
        when (step) {
            CameraConnectionStep.PairingConfirmation -> CameraConnectionRetryTarget.PairingConfirmation
            CameraConnectionStep.JoinCameraWifi -> CameraConnectionRetryTarget.WifiHandoffWithoutBle
            CameraConnectionStep.LoadGallery -> CameraConnectionRetryTarget.ExistingPtpProbe
            CameraConnectionStep.ConnectPtp,
            CameraConnectionStep.RegistrationConsistencyCheck -> CameraConnectionRetryTarget.ResetConnection
            CameraConnectionStep.StaleBondCheck,
            CameraConnectionStep.BleScan,
            CameraConnectionStep.BleHandshake,
            CameraConnectionStep.EnvironmentCheck,
            null -> CameraConnectionRetryTarget.PairingScan
            CameraConnectionStep.CameraPairingMode -> CameraConnectionRetryTarget.PairingModeConfirmation
            else -> CameraConnectionRetryTarget.GalleryEntryWithBle
        }
}

internal object CameraConnectionEntryPolicy {
    fun shouldProbeExistingPtpBeforeBle(state: ConnectionState, hasRememberedPairing: Boolean): Boolean =
        state == ConnectionState.ERROR && hasRememberedPairing
}

internal object CameraConnectionStatusPolicy {
    fun pairingState(status: String, currentState: ConnectionState): ConnectionState =
        when {
            "搜索" in status -> ConnectionState.SCANNING
            "蓝牙" in status -> ConnectionState.CONNECTING_BLE
            "确认" in status -> ConnectionState.WAITING_CAMERA_CONFIRMATION
            "配对成功" in status -> ConnectionState.PAIRED
            status.hasWifiText() -> ConnectionState.CONNECTING_WIFI
            status.hasAlbumChannelText() -> ConnectionState.CONNECTING_PTP
            else -> currentState
        }

    fun galleryState(status: String, currentState: ConnectionState): ConnectionState =
        when {
            status.hasTransferAuthorizationText() ||
                status.hasCameraWifiActivationText() ||
                status.hasCameraWifiReadyWaitText() -> ConnectionState.CONNECTING_BLE
            status.hasWifiText() -> ConnectionState.CONNECTING_WIFI
            status.hasAlbumChannelText() -> ConnectionState.CONNECTING_PTP
            status.hasGalleryModeConfirmationText() -> ConnectionState.CONNECTING_PTP
            "已连接" in status -> ConnectionState.CONNECTED
            status.hasRememberedBleReconnectText() ||
                "蓝牙" in status ||
                "传图" in status ||
                "相机允许" in status -> ConnectionState.CONNECTING_BLE
            else -> currentState
        }

    fun pairingStep(status: String, currentStep: CameraConnectionStep): CameraConnectionStep =
        when {
            "搜索" in status -> CameraConnectionStep.BleScan
            "蓝牙" in status -> CameraConnectionStep.BleHandshake
            "确认" in status -> CameraConnectionStep.PairingConfirmation
            else -> currentStep
        }

    fun galleryStep(status: String, currentStep: CameraConnectionStep): CameraConnectionStep =
        when {
            status.hasRememberedBleReconnectText() -> CameraConnectionStep.ReconnectPairedBle
            status.hasTransferAuthorizationText() -> CameraConnectionStep.TransferAuthorization
            status.hasCameraWifiActivationText() -> CameraConnectionStep.ActivateCameraWifi
            status.hasCameraWifiReadyWaitText() -> CameraConnectionStep.WaitCameraWifiReady
            status.hasWifiText() -> CameraConnectionStep.JoinCameraWifi
            status.hasAlbumChannelText() -> CameraConnectionStep.ConnectPtp
            status.hasGalleryModeConfirmationText() -> CameraConnectionStep.ConfirmGalleryMode
            "恢复" in status || "触发" in status || "传图" in status -> CameraConnectionStep.ActivateCameraWifi
            "已连接" in status -> CameraConnectionStep.LoadGallery
            else -> currentStep
        }

    private fun String.hasWifiText(): Boolean =
        "WiFi" in this || "Wi-Fi" in this || "Wi‑Fi" in this

    private fun String.hasAlbumChannelText(): Boolean =
        "PTP" in this || "相册通道" in this

    private fun String.hasTransferAuthorizationText(): Boolean =
        "确认相机允许" in this

    private fun String.hasCameraWifiActivationText(): Boolean =
        "让相机打开" in this && hasWifiText()

    private fun String.hasCameraWifiReadyWaitText(): Boolean =
        "等待相机确认" in this && "准备好" in this && hasWifiText()

    private fun String.hasGalleryModeConfirmationText(): Boolean =
        "确认相机" in this && "相册模式" in this

    private fun String.hasRememberedBleReconnectText(): Boolean =
        "直连已配对相机" in this ||
            "查找已配对相机" in this ||
            "唤醒已配对相机" in this ||
            "复用刚才的相机蓝牙连接" in this ||
            "这台已配对相机" in this
}
