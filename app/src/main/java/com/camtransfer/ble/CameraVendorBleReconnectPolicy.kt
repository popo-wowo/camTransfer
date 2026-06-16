package com.camtransfer.ble

enum class CameraVendorBleReconnectStage {
    DirectAddress,
    FastScan,
    ScanFallback,
}

object CameraVendorBleReconnectPolicy {
    const val MAX_REMEMBERED_RECONNECT_ATTEMPTS = 3
    const val REMEMBERED_DIRECT_CONNECT_TIMEOUT_MS = 6_000L
    const val REMEMBERED_FAST_SCAN_TIMEOUT_MS = 4_000L
    const val REMEMBERED_SCAN_TIMEOUT_MS = 12_000L

    fun reconnectStages(
        hasRememberedBluetoothAddress: Boolean,
        hasStableCameraIdentity: Boolean = false,
    ): List<CameraVendorBleReconnectStage> =
        if (hasStableCameraIdentity) {
            listOf(
                CameraVendorBleReconnectStage.FastScan,
                CameraVendorBleReconnectStage.ScanFallback,
            )
        } else if (hasRememberedBluetoothAddress) {
            listOf(
                CameraVendorBleReconnectStage.DirectAddress,
                CameraVendorBleReconnectStage.FastScan,
                CameraVendorBleReconnectStage.ScanFallback,
            )
        } else {
            listOf(CameraVendorBleReconnectStage.ScanFallback)
        }

    fun retryDelayMs(afterFailedAttempt: Int): Long {
        return 500L * afterFailedAttempt.coerceAtLeast(1)
    }
}
