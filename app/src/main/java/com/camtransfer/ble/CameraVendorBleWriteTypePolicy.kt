package com.camtransfer.ble

import java.util.UUID

object CameraVendorBleWriteTypePolicy {
    private val responseRequiredCharacteristics = setOf(
        CameraVendorBleProfile.PAIR_TOKEN_CHAR,
        CameraVendorBleProfile.IDENTIFIER_CHAR,
        CameraVendorBleProfile.SECURE_STATUS_CHAR,
        CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_CHAR,
        CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_EX_CHAR,
        CameraVendorBleProfile.IMAGE_RESIZE_SETTING_CHAR,
        CameraVendorBleProfile.LAUNCH_REQUEST_CHAR,
    )

    fun shouldWriteWithResponse(characteristicUuid: UUID, hasGattWriteProperty: Boolean): Boolean {
        return characteristicUuid in responseRequiredCharacteristics || hasGattWriteProperty
    }
}
