package com.camtransfer.ble

object CameraVendorBleTransferActivationPolicy {
    private val ResizeDisabledPayload = byteArrayOf(0x00)
    private val ResizeEnabledPayload = byteArrayOf(0x01)

    fun isReadyToJoinWifi(apState: ByteArray?): Boolean {
        if (apState == null || apState.size < 2) return false
        val value = (apState[0].toInt() and 0xFF) or ((apState[1].toInt() and 0xFF) shl 8)
        return value == 0x8001 || value == 0x8003
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

    fun shouldFastHandoffAfterCommandWrites(): Boolean = true

    fun shouldActivelyDisconnectBluetoothBeforeWifi(): Boolean = true

    const val BLUETOOTH_RELEASE_DELAY_MS = 1_500L
}
