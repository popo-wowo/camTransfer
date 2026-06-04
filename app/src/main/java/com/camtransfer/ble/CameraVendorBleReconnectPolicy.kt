package com.camtransfer.ble

object CameraVendorBleReconnectPolicy {
    const val MAX_REMEMBERED_RECONNECT_ATTEMPTS = 3
    const val REMEMBERED_DIRECT_CONNECT_TIMEOUT_MS = 6_000L
    const val REMEMBERED_FAST_SCAN_TIMEOUT_MS = 4_000L
    const val REMEMBERED_SCAN_TIMEOUT_MS = 12_000L

    fun retryDelayMs(afterFailedAttempt: Int): Long {
        return 500L * afterFailedAttempt.coerceAtLeast(1)
    }
}
