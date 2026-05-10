package com.camtransfer.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.service.CameraService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class ConnectionState { IDLE, SCANNING, CONNECTING_BLE, CONNECTING_WIFI, CONNECTING_PTP, CONNECTED, ERROR }

class ConnectionViewModel(app: Application) : AndroidViewModel(app) {

    val cameraService = CameraService(app.applicationContext)

    private val _state = MutableStateFlow(ConnectionState.IDLE)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _statusText = MutableStateFlow("")
    val statusText: StateFlow<String> = _statusText.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun connect() {
        if (_state.value == ConnectionState.CONNECTED) return
        _state.value = ConnectionState.SCANNING
        _error.value = null

        viewModelScope.launch {
            try {
                cameraService.connectToCamera { status ->
                    _statusText.value = status
                    _state.value = when {
                        "搜索" in status -> ConnectionState.SCANNING
                        "蓝牙" in status -> ConnectionState.CONNECTING_BLE
                        "WiFi" in status -> ConnectionState.CONNECTING_WIFI
                        "PTP" in status -> ConnectionState.CONNECTING_PTP
                        else -> ConnectionState.CONNECTED
                    }
                }
                _state.value = ConnectionState.CONNECTED
            } catch (e: Exception) {
                _state.value = ConnectionState.ERROR
                _error.value = e.message ?: "连接失败"
            }
        }
    }

    fun disconnect() {
        viewModelScope.launch {
            cameraService.disconnect()
            _state.value = ConnectionState.IDLE
            _statusText.value = ""
        }
    }

    override fun onCleared() {
        super.onCleared()
        viewModelScope.launch { cameraService.disconnect() }
    }
}
