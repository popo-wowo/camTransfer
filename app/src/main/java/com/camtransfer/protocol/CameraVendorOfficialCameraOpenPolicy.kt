package com.camtransfer.protocol

object CameraVendorOfficialCameraOpenPolicy {
    const val STARTUP_DELAY_MS = 3_000L
    const val OPEN_ATTEMPT_TIMEOUT_MS = 1_500L
    const val INIT_ACK_READ_TIMEOUT_MS = 15_000L
    const val COMMAND_READ_TIMEOUT_MS = 15_000L
    const val MAX_OPEN_ATTEMPTS = 5

    fun openAttemptTimeouts(): List<Long> =
        List(MAX_OPEN_ATTEMPTS) { OPEN_ATTEMPT_TIMEOUT_MS }

    fun retryDelayMs(afterFailedAttempt: Int): Long =
        500L * afterFailedAttempt.coerceAtLeast(1)
}
