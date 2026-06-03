package com.camtransfer.protocol

object CameraVendorPtpConnectionStartupPolicy {
    const val MAX_CONNECT_ATTEMPTS = 5
    const val STARTUP_DELAY_MS = 500L

    fun retryDelayMs(afterFailedAttempt: Int): Long {
        return 500L * afterFailedAttempt.coerceAtLeast(1)
    }
}
