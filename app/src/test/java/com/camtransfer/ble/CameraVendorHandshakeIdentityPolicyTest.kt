package com.camtransfer.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorHandshakeIdentityPolicyTest {

    @Test
    fun connectedDeviceNameUsesReferenceAppStyleName() {
        assertEquals(
            "iPhone-6970",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("  Xiaomi 14  "),
        )
    }

    @Test
    fun connectedDeviceNameUsesReferenceAppStyleNameWhenInputIsEmpty() {
        assertEquals(
            "iPhone-6970",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("   "),
        )
        assertEquals(
            "iPhone-6970",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName(null),
        )
    }
}
