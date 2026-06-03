package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorPtpConnectionStartupPolicyTest {
    @Test
    fun mirrorsIosPtpStartupDelayAndRetryPolicy() {
        assertEquals(500L, CameraVendorPtpConnectionStartupPolicy.STARTUP_DELAY_MS)
        assertEquals(5, CameraVendorPtpConnectionStartupPolicy.MAX_CONNECT_ATTEMPTS)
        assertEquals(500L, CameraVendorPtpConnectionStartupPolicy.retryDelayMs(afterFailedAttempt = 1))
        assertEquals(1_000L, CameraVendorPtpConnectionStartupPolicy.retryDelayMs(afterFailedAttempt = 2))
    }
}
