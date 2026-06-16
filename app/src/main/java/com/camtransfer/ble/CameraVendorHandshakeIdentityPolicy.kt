package com.camtransfer.ble

import java.util.Locale

object CameraVendorHandshakeIdentityPolicy {
    private const val FALLBACK_CONNECTED_DEVICE_NAME = "CamTransfer"
    private const val REFERENCE_APP_GENERIC_PHONE_PREFIX = "iPhone"

    fun currentConnectedDeviceName(): String = referenceAppStyleGenericPhoneName()

    fun connectedDeviceName(preferredDeviceName: String?): String = referenceAppStyleGenericPhoneName()

    private fun referenceAppStyleGenericPhoneName(): String {
        val suffix = FALLBACK_CONNECTED_DEVICE_NAME.toByteArray(Charsets.UTF_8)
            .fold(0) { partial, byte ->
                (partial * 31 + (byte.toInt() and 0xFF)) % 10_000
            }
        return String.format(Locale.US, "%s-%04d", REFERENCE_APP_GENERIC_PHONE_PREFIX, suffix)
    }
}
