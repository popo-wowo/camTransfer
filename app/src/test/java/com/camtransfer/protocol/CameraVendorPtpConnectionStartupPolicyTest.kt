package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorPtpConnectionStartupPolicyTest {
    @Test
    fun startsPtpOpenImmediatelyAfterWifiIsAvailable() {
        assertEquals(0L, CameraVendorPtpConnectionStartupPolicy.STARTUP_DELAY_MS)
        assertEquals(5, CameraVendorPtpConnectionStartupPolicy.MAX_CONNECT_ATTEMPTS)
        assertEquals(1_500L, CameraVendorPtpConnectionStartupPolicy.OPEN_ATTEMPT_TIMEOUT_MS)
        assertEquals(15_000L, CameraVendorPtpConnectionStartupPolicy.INIT_ACK_READ_TIMEOUT_MS)
        assertEquals(15_000L, CameraVendorPtpConnectionStartupPolicy.COMMAND_READ_TIMEOUT_MS)
        assertEquals(500L, CameraVendorPtpConnectionStartupPolicy.retryDelayMs(afterFailedAttempt = 1))
        assertEquals(1_000L, CameraVendorPtpConnectionStartupPolicy.retryDelayMs(afterFailedAttempt = 2))
    }
}
