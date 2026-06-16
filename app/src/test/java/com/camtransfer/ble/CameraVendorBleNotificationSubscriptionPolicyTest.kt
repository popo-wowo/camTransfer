package com.camtransfer.ble

import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorBleNotificationSubscriptionPolicyTest {
    @Test
    fun handshakePreparationSubscribesCameraStateCharacteristics() {
        val characteristics = listOf(
            CameraVendorBleProfile.CAMERA_WIFI_SSID_CHAR,
            CameraVendorBleProfile.CAMERA_WIFI_PASSPHRASE_CHAR,
            CameraVendorBleProfile.CAMERA_WIFI_MAC_ADDRESS_CHAR,
            CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_CHAR,
            CameraVendorBleProfile.IMAGE_TRANSFER_SETTING_EX_CHAR,
            CameraVendorBleProfile.IMAGE_RESIZE_SETTING_CHAR,
            CameraVendorBleProfile.LAUNCH_REQUEST_CHAR,
            CameraVendorBleProfile.AP_STATE_CHAR,
            CameraVendorBleProfile.TRANSFER_STATE_CHAR,
            CameraVendorBleProfile.SECURE_STATUS_CHAR,
        )

        characteristics.forEach { uuid ->
            assertTrue(
                "Handshake should subscribe $uuid when it is notifiable",
                CameraVendorBleNotificationSubscriptionPolicy.shouldSubscribeDuringHandshake(uuid),
            )
        }
    }
}
