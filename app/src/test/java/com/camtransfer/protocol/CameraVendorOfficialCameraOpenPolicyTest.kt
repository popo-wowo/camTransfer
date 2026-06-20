package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorOfficialCameraOpenPolicyTest {
    @Test
    fun cameraOpenTriesImmediatelyAfterWifiIsAvailable() {
        assertEquals(0L, CameraVendorOfficialCameraOpenPolicy.STARTUP_DELAY_MS)
        assertEquals(1_500L, CameraVendorOfficialCameraOpenPolicy.OPEN_ATTEMPT_TIMEOUT_MS)
        assertEquals(15_000L, CameraVendorOfficialCameraOpenPolicy.INIT_ACK_READ_TIMEOUT_MS)
        assertEquals(15_000L, CameraVendorOfficialCameraOpenPolicy.COMMAND_READ_TIMEOUT_MS)
        assertEquals(5, CameraVendorOfficialCameraOpenPolicy.MAX_OPEN_ATTEMPTS)
        assertEquals(
            listOf(1_500L, 1_500L, 1_500L, 1_500L, 1_500L),
            CameraVendorOfficialCameraOpenPolicy.openAttemptTimeouts(),
        )
        assertEquals(500L, CameraVendorOfficialCameraOpenPolicy.retryDelayMs(afterFailedAttempt = 1))
        assertEquals(1_000L, CameraVendorOfficialCameraOpenPolicy.retryDelayMs(afterFailedAttempt = 2))
    }
}
