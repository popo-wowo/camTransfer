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
    fun connectedDeviceNameUsesReferenceAppStyleNameForAnyInput() {
        assertEquals(
            "iPhone-6970",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName(" Xiaomi\t14\nPro "),
        )
        assertEquals(
            "iPhone-6970",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("   "),
        )
        assertEquals(
            "iPhone-6970",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName(null),
        )
        assertEquals(
            "iPhone-6970",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("x".repeat(64)),
        )
    }

    @Test
    fun connectedDeviceNameDecisionRecordsReferenceAppCompatibility() {
        val decision = CameraVendorHandshakeIdentityPolicy.connectedDeviceNameDecision("x".repeat(64))

        assertEquals("iPhone-6970", decision.name)
        assertEquals("reference_app_compatibility_name", decision.source)
        assertEquals(64, decision.rawLength)
    }

}
