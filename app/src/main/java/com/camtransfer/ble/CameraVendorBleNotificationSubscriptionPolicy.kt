package com.camtransfer.ble

import java.util.UUID

object CameraVendorBleNotificationSubscriptionPolicy {
    fun shouldSubscribeDuringHandshake(characteristicUuid: UUID): Boolean = true
}
