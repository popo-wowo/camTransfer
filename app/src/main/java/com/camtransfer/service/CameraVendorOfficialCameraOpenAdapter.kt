package com.camtransfer.service

import com.camtransfer.protocol.CameraVendorOfficialCameraOpenPolicy
import kotlinx.coroutines.delay

class CameraVendorOfficialCameraOpenAdapter(
    private val attemptTimeoutsMs: List<Long> = CameraVendorOfficialCameraOpenPolicy.openAttemptTimeouts(),
    private val startupDelayMs: Long = CameraVendorOfficialCameraOpenPolicy.STARTUP_DELAY_MS,
    private val retryDelayMs: (Int) -> Long = CameraVendorOfficialCameraOpenPolicy::retryDelayMs,
) {
    suspend fun open(
        onAttempt: suspend (attempt: Int, total: Int, timeoutMs: Long) -> Unit = { _, _, _ -> },
        onFailure: suspend (attempt: Int, total: Int, error: Throwable) -> Unit = { _, _, _ -> },
        onWaitingForStartup: suspend (delayMs: Long) -> Unit = {},
        onWaitingForRetry: suspend (attempt: Int, delayMs: Long) -> Unit = { _, _ -> },
        openOnce: suspend (timeoutMs: Long) -> Unit,
    ) {
        var lastError: Throwable? = null
        val total = attemptTimeoutsMs.size
        if (startupDelayMs > 0) {
            onWaitingForStartup(startupDelayMs)
            delay(startupDelayMs)
        }
        for ((index, timeoutMs) in attemptTimeoutsMs.withIndex()) {
            try {
                onAttempt(index + 1, total, timeoutMs)
                openOnce(timeoutMs)
                return
            } catch (error: Throwable) {
                if (CameraConnectionCancellationPolicy.shouldPropagate(error)) throw error
                lastError = error
                onFailure(index + 1, total, error)
                if (index < attemptTimeoutsMs.lastIndex) {
                    val retryDelay = retryDelayMs(index + 1)
                    if (retryDelay > 0) {
                        onWaitingForRetry(index + 1, retryDelay)
                        delay(retryDelay)
                    }
                }
            }
        }
        throw IllegalStateException("相机 PTP 通信会话连接失败，请确认相机仍停留在传图/相册模式后重试", lastError)
    }
}
