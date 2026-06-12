package com.camtransfer.ble

object CameraVendorBleTransferActivationPolicy {
    private val ResizeDisabledPayload = byteArrayOf(0x00)
    private val ResizeEnabledPayload = byteArrayOf(0x01)

    fun isReadyToJoinWifi(apState: ByteArray?): Boolean {
        val value = apStateValue(apState) ?: return false
        return value == 0x8001 || value == 0x8003
    }

    fun isApLaunchInProgress(apState: ByteArray?): Boolean =
        apStateValue(apState) == 0x8000

    fun shouldProceedToWifiAfterReadyWait(lastApState: ByteArray?): Boolean =
        isApLaunchInProgress(lastApState)

    fun apStateHex(apState: ByteArray?): String =
        apStateValue(apState)?.let { "0x${it.toString(16)}" } ?: "none"

    private fun apStateValue(apState: ByteArray?): Int? {
        if (apState == null || apState.size < 2) return null
        return (apState[0].toInt() and 0xFF) or ((apState[1].toInt() and 0xFF) shl 8)
    }

    fun defaultPreferCompressedDownloads(): Boolean = true

    fun resizePayload(preferCompressedDownloads: Boolean): ByteArray =
        if (preferCompressedDownloads) ResizeEnabledPayload else ResizeDisabledPayload

    fun statusText(preferCompressedDownloads: Boolean): String =
        if (preferCompressedDownloads) {
            "当前模式：压缩 ~3M"
        } else {
            "当前模式：原图"
        }

    fun shouldFastHandoffAfterCommandWrites(): Boolean = false

    fun shouldActivelyDisconnectBluetoothBeforeWifi(): Boolean = true

    const val AP_READY_TIMEOUT_MS = 6_000L
    const val AP_READY_POLL_INTERVAL_MS = 250L
    const val AP_READY_READ_TIMEOUT_MS = 1_000L
    const val BLUETOOTH_RELEASE_DELAY_MS = 500L
}
