package com.camtransfer.ble

import java.util.Locale

data class CameraVendorConnectedDeviceNameDecision(
    val name: String,
    val source: String,
    val rawLength: Int,
    val normalizedLength: Int,
)

object CameraVendorHandshakeIdentityPolicy {
    private const val FALLBACK_CONNECTED_DEVICE_NAME = "CamTransfer"
    private const val REFERENCE_APP_GENERIC_PHONE_PREFIX = "iPhone"

    fun currentConnectedDeviceName(): String = currentConnectedDeviceNameDecision().name

    fun currentConnectedDeviceNameDecision(): CameraVendorConnectedDeviceNameDecision =
        connectedDeviceNameDecision(null)

    fun connectedDeviceName(preferredDeviceName: String?): String =
        connectedDeviceNameDecision(preferredDeviceName).name

    fun connectedDeviceNameDecision(preferredDeviceName: String?): CameraVendorConnectedDeviceNameDecision {
        val normalized = preferredDeviceName.orEmpty().trim()
        return CameraVendorConnectedDeviceNameDecision(
            name = referenceAppStyleGenericPhoneName(),
            source = "reference_app_compatibility_name",
            rawLength = preferredDeviceName?.length ?: 0,
            normalizedLength = normalized.length,
        )
    }

    private fun referenceAppStyleGenericPhoneName(): String {
        val suffix = FALLBACK_CONNECTED_DEVICE_NAME.toByteArray(Charsets.UTF_8)
            .fold(0) { partial, byte ->
                (partial * 31 + (byte.toInt() and 0xFF)) % 10_000
            }
        return String.format(Locale.US, "%s-%04d", REFERENCE_APP_GENERIC_PHONE_PREFIX, suffix)
    }
}
