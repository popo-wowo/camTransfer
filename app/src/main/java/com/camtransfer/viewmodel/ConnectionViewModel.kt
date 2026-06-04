package com.camtransfer.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.ble.CameraVendorBleTransferActivationPolicy
import com.camtransfer.service.CameraConnectionIssue
import com.camtransfer.service.CameraConnectionIssueClassifier
import com.camtransfer.service.CameraConnectionMode
import com.camtransfer.service.CameraConnectionStep
import com.camtransfer.service.CameraService
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

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

    private var connectionJob: Job? = null

    init {
        DiagnosticLog.append(appContext, "App", "ConnectionViewModel initialized")
        cameraService.rememberedPairing()?.let { remembered ->
            _state.value = ConnectionState.PAIRED
            _statusText.value = "已配对 ${remembered.deviceName}"
            DiagnosticLog.append(appContext, "Connection", "Remembered pairing exists")
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
        val entryState = _state.value
        cancelConnectionJob()
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
        if (_state.value != ConnectionState.PAIRED) return
        _error.value = null
        _connectionIssue.value = null
        _activeStep.value = CameraConnectionStep.ReconnectPairedBle
        cancelConnectionJob()
        connectionJob = viewModelScope.launch {
            var currentStep = CameraConnectionStep.ReconnectPairedBle
            try {
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
                DiagnosticLog.append(appContext, "Connection", "Gallery connection established")
                publishGalleryConnectionEvent()
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                DiagnosticLog.append(appContext, "Connection", "Enter gallery failed", e)
                publishIssue(currentStep, e)
                _state.value = ConnectionState.PAIRED
                val remembered = cameraService.rememberedPairing()
                _statusText.value = remembered?.let { "已配对 ${it.deviceName}" } ?: "已保存配对"
                _error.value = e.message ?: "进入相册失败"
            }
        }
    }

    fun confirmWifiJoinedAndOpenGallery() {
        _error.value = null
        _connectionIssue.value = null
        _connectionMode.value = CameraConnectionMode.GUIDED
        _activeStep.value = CameraConnectionStep.ConnectPtp
        cancelConnectionJob()
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

    fun retryCurrentIssue() {
        when (connectionIssue.value?.step) {
            CameraConnectionStep.PairingConfirmation -> confirmCameraPairingSucceeded()
            CameraConnectionStep.JoinCameraWifi,
            CameraConnectionStep.ConnectPtp,
            CameraConnectionStep.LoadGallery -> confirmWifiJoinedAndOpenGallery()
            CameraConnectionStep.StaleBondCheck,
            CameraConnectionStep.BleScan,
            CameraConnectionStep.BleHandshake,
            CameraConnectionStep.EnvironmentCheck,
            null -> connect()
            CameraConnectionStep.CameraPairingMode -> confirmCameraPairingModeAndStartScan()
            else -> enterCameraAlbum()
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
            cameraService.disconnect()
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
        viewModelScope.launch {
            DiagnosticLog.append(appContext, "Connection", "Forget pairing requested")
            cancelConnectionJob()
            cameraService.forgetPairing()
            _state.value = ConnectionState.IDLE
            _statusText.value = ""
            _error.value = null
            _connectionIssue.value = null
            _activeStep.value = null
        }
    }

    private fun publishIssue(step: CameraConnectionStep, error: Throwable) {
        val issue = CameraConnectionIssueClassifier.fromThrowable(step, error)
        _connectionIssue.value = issue
        _activeStep.value = issue.step
        DiagnosticLog.append(
            appContext,
            "ConnectionIssue",
            "mode=${_connectionMode.value} phase=${issue.phase} step=${issue.step} failure=${issue.failure} action=${issue.primaryAction}",
        )
    }

    private fun publishGalleryConnectionEvent() {
        _galleryConnectionEvent.value += 1
    }

    private fun cancelConnectionJob() {
        connectionJob?.cancel()
        connectionJob = null
    }

    override fun onCleared() {
        super.onCleared()
        cancelConnectionJob()
        viewModelScope.launch { cameraService.disconnect() }
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
            status.hasWifiText() -> ConnectionState.CONNECTING_WIFI
            status.hasAlbumChannelText() -> ConnectionState.CONNECTING_PTP
            "已连接" in status -> ConnectionState.CONNECTED
            "蓝牙" in status || "传图" in status || "相机允许" in status -> ConnectionState.CONNECTING_BLE
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
            "恢复" in status || "触发" in status || "传图" in status -> CameraConnectionStep.ActivateCameraWifi
            status.hasWifiText() -> CameraConnectionStep.JoinCameraWifi
            status.hasAlbumChannelText() -> CameraConnectionStep.ConnectPtp
            "已连接" in status -> CameraConnectionStep.LoadGallery
            else -> currentStep
        }

    private fun String.hasWifiText(): Boolean =
        "WiFi" in this || "Wi-Fi" in this || "Wi‑Fi" in this

    private fun String.hasAlbumChannelText(): Boolean =
        "PTP" in this || "相册通道" in this
}
