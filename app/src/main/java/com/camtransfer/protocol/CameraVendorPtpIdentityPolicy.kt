package com.camtransfer.protocol

object CameraVendorPtpIdentityPolicy {
    private const val FallbackLegacyInitFriendlyName = "CamTransfer-6970"

    fun legacyInitFriendlyName(connectedDeviceName: String? = null): String {
        val candidate = connectedDeviceName?.trim().orEmpty()
        val bytesWithNullTerminator = candidate.toByteArray(Charsets.UTF_16LE).size + 2
        return candidate
            .takeIf { it.isNotEmpty() && bytesWithNullTerminator <= CameraVendorConst.INIT_DEVICE_NAME_BYTE_COUNT }
            ?: FallbackLegacyInitFriendlyName
    }
}
