package com.camtransfer.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorHandshakeIdentityPolicyTest {

    @Test
    fun connectedDeviceNamePrefersTrimmedDeviceName() {
        assertEquals(
            "Xiaomi 14",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("  Xiaomi 14  "),
        )
    }

    @Test
    fun connectedDeviceNameFallsBackToAppName() {
        assertEquals(
            "CamTransfer",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("   "),
        )
        assertEquals(
            "CamTransfer",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName(null),
        )
    }
}
