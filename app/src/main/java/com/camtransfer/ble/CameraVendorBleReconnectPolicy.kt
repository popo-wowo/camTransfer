package com.camtransfer.ble

enum class CameraVendorBleReconnectStage {
    DirectAddress,
    OfficialReconnectScan,
}

object CameraVendorBleReconnectPolicy {
    const val REMEMBERED_DIRECT_CONNECT_TIMEOUT_MS = 15_000L
    const val REMEMBERED_RECONNECT_SCAN_TIMEOUT_MS = 12_000L

    fun reconnectStages(
        hasRememberedBluetoothAddress: Boolean,
        hasStableCameraIdentity: Boolean = false,
    ): List<CameraVendorBleReconnectStage> {
        val stages = mutableListOf<CameraVendorBleReconnectStage>()
        if (hasRememberedBluetoothAddress) {
            stages += CameraVendorBleReconnectStage.DirectAddress
        }
        if (hasStableCameraIdentity) {
            stages += CameraVendorBleReconnectStage.OfficialReconnectScan
        }
        return stages
    }
}
