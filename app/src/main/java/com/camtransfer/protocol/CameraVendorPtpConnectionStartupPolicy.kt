package com.camtransfer.protocol

object CameraVendorPtpConnectionStartupPolicy {
    const val MAX_CONNECT_ATTEMPTS = CameraVendorOfficialCameraOpenPolicy.MAX_OPEN_ATTEMPTS
    const val STARTUP_DELAY_MS = CameraVendorOfficialCameraOpenPolicy.STARTUP_DELAY_MS
    const val OPEN_ATTEMPT_TIMEOUT_MS = CameraVendorOfficialCameraOpenPolicy.OPEN_ATTEMPT_TIMEOUT_MS
    const val INIT_ACK_READ_TIMEOUT_MS = CameraVendorOfficialCameraOpenPolicy.INIT_ACK_READ_TIMEOUT_MS
    const val COMMAND_READ_TIMEOUT_MS = CameraVendorOfficialCameraOpenPolicy.COMMAND_READ_TIMEOUT_MS

    fun retryDelayMs(afterFailedAttempt: Int): Long =
        CameraVendorOfficialCameraOpenPolicy.retryDelayMs(afterFailedAttempt)
}
