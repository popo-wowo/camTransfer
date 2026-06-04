package com.camtransfer.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorBleReconnectPolicyTest {
    @Test
    fun retriesRememberedCameraGattReconnects() {
        assertEquals(3, CameraVendorBleReconnectPolicy.MAX_REMEMBERED_RECONNECT_ATTEMPTS)
        assertEquals(6_000L, CameraVendorBleReconnectPolicy.REMEMBERED_DIRECT_CONNECT_TIMEOUT_MS)
        assertEquals(4_000L, CameraVendorBleReconnectPolicy.REMEMBERED_FAST_SCAN_TIMEOUT_MS)
        assertEquals(12_000L, CameraVendorBleReconnectPolicy.REMEMBERED_SCAN_TIMEOUT_MS)
        assertEquals(500L, CameraVendorBleReconnectPolicy.retryDelayMs(afterFailedAttempt = 1))
        assertEquals(1_000L, CameraVendorBleReconnectPolicy.retryDelayMs(afterFailedAttempt = 2))
    }
}
