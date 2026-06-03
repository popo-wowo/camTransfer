package com.camtransfer.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorBleReconnectPolicyTest {
    @Test
    fun retriesRememberedCameraGattReconnects() {
        assertEquals(3, CameraVendorBleReconnectPolicy.MAX_REMEMBERED_RECONNECT_ATTEMPTS)
        assertEquals(12_000L, CameraVendorBleReconnectPolicy.REMEMBERED_SCAN_TIMEOUT_MS)
        assertEquals(500L, CameraVendorBleReconnectPolicy.retryDelayMs(afterFailedAttempt = 1))
        assertEquals(1_000L, CameraVendorBleReconnectPolicy.retryDelayMs(afterFailedAttempt = 2))
    }
}
