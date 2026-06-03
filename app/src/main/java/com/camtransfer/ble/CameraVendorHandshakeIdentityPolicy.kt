package com.camtransfer.ble

import android.os.Build

object CameraVendorHandshakeIdentityPolicy {
    private const val FALLBACK_CONNECTED_DEVICE_NAME = "CamTransfer"

    fun currentConnectedDeviceName(): String {
        val model = Build.MODEL?.trim().orEmpty()
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val preferred = when {
            model.isNotEmpty() && manufacturer.isNotEmpty() &&
                !model.startsWith(manufacturer, ignoreCase = true) -> "$manufacturer $model"
            model.isNotEmpty() -> model
            manufacturer.isNotEmpty() -> manufacturer
            else -> FALLBACK_CONNECTED_DEVICE_NAME
        }
        return connectedDeviceName(preferred)
    }

    fun connectedDeviceName(preferredDeviceName: String?): String {
        val trimmed = preferredDeviceName?.trim().orEmpty()
        return trimmed.ifEmpty { FALLBACK_CONNECTED_DEVICE_NAME }
    }
}
