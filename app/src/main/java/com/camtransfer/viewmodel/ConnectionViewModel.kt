package com.camtransfer.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.ble.CameraVendorBleTransferActivationPolicy
import com.camtransfer.service.CameraService
import com.camtransfer.service.DiagnosticLog
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

    private val _preferCompressedDownloads = MutableStateFlow(cameraService.preferCompressedDownloads())
    val preferCompressedDownloads: StateFlow<Boolean> = _preferCompressedDownloads.asStateFlow()

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
        val entryState = _state.value
        _state.value = ConnectionState.SCANNING
        _error.value = null
        DiagnosticLog.append(appContext, "Connection", "Connect started")
        val hasRememberedPairing = cameraService.rememberedPairing() != null

        viewModelScope.launch {
            try {
                if (CameraConnectionEntryPolicy.shouldProbeExistingPtpBeforeBle(entryState, hasRememberedPairing)) {
                    val directPtpConnected = cameraService.connectExistingCameraWifiToGallery { status ->
                        DiagnosticLog.append(appContext, "ConnectionStatus", status)
                        _statusText.value = status
                        _state.value = when {
                            "已连接" in status -> ConnectionState.CONNECTED
                            else -> ConnectionState.CONNECTING_PTP
                        }
                    }
                    if (directPtpConnected) {
                        _state.value = ConnectionState.CONNECTED
                        DiagnosticLog.append(appContext, "Connection", "Connected through existing PTP session")
                        return@launch
                    }
                    _state.value = ConnectionState.SCANNING
                }
                cameraService.pairWithCamera { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    _statusText.value = status
                    _state.value = CameraConnectionStatusPolicy.pairingState(status, _state.value)
                }
                _state.value = ConnectionState.WAITING_CAMERA_CONFIRMATION
            } catch (e: Exception) {
                DiagnosticLog.append(appContext, "Connection", "Connect failed", e)
                _state.value = ConnectionState.ERROR
                _error.value = e.message ?: "连接失败"
            }
        }
    }

    fun confirmCameraPairingSucceeded() {
        if (_state.value != ConnectionState.WAITING_CAMERA_CONFIRMATION) return
        _error.value = null
        viewModelScope.launch {
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
                val remembered = cameraService.rememberedPairing()
                _statusText.value = remembered?.let { "已配对 ${it.deviceName}" } ?: "配对成功"
                DiagnosticLog.append(appContext, "Connection", "Pairing confirmed")
            } catch (e: Exception) {
                DiagnosticLog.append(appContext, "Connection", "Pairing confirmation failed", e)
                _state.value = ConnectionState.ERROR
                _error.value = e.message ?: "连接失败"
            }
        }
    }

    fun enterCameraAlbum() {
        if (_state.value != ConnectionState.PAIRED) return
        _error.value = null
        viewModelScope.launch {
            try {
                cameraService.connectPairedCameraToGallery { status ->
                    DiagnosticLog.append(appContext, "ConnectionStatus", status)
                    _statusText.value = status
                    _state.value = when {
                        "WiFi" in status -> ConnectionState.CONNECTING_WIFI
                        "PTP" in status -> ConnectionState.CONNECTING_PTP
                        "已连接" in status -> ConnectionState.CONNECTED
                        else -> ConnectionState.CONNECTING_BLE
                    }
                }
                _state.value = ConnectionState.CONNECTED
                DiagnosticLog.append(appContext, "Connection", "Gallery connection established")
            } catch (e: Exception) {
                DiagnosticLog.append(appContext, "Connection", "Enter gallery failed", e)
                _state.value = ConnectionState.PAIRED
                val remembered = cameraService.rememberedPairing()
                _statusText.value = remembered?.let { "已配对 ${it.deviceName}" } ?: "配对成功"
                _error.value = e.message ?: "进入相册失败"
            }
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
            cameraService.disconnect()
            _state.value = ConnectionState.IDLE
            cameraService.rememberedPairing()?.let { remembered ->
                _state.value = ConnectionState.PAIRED
                _statusText.value = "已配对 ${remembered.deviceName}"
            } ?: run {
                _statusText.value = ""
            }
            _error.value = null
        }
    }

    fun forgetPairing() {
        viewModelScope.launch {
            DiagnosticLog.append(appContext, "Connection", "Forget pairing requested")
            cameraService.forgetPairing()
            _state.value = ConnectionState.IDLE
            _statusText.value = ""
            _error.value = null
        }
    }

    override fun onCleared() {
        super.onCleared()
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
            "WiFi" in status -> ConnectionState.CONNECTING_WIFI
            "PTP" in status -> ConnectionState.CONNECTING_PTP
            else -> currentState
        }
}
