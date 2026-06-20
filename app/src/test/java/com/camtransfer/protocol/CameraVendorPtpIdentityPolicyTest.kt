package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPtpIdentityPolicyTest {

    @Test
    fun legacyInitUsesConnectedDeviceNameWhenItFitsWireField() {
        assertEquals(
            "Xiaomi 14",
            CameraVendorPtpIdentityPolicy.legacyInitFriendlyName("Xiaomi 14"),
        )
    }

    @Test
    fun legacyInitFriendlyNameFitsFixedWireField() {
        val bytesWithNullTerminator =
            CameraVendorPtpIdentityPolicy.legacyInitFriendlyName("CamTransfer-6970").toByteArray(Charsets.UTF_16LE).size + 2

        assertTrue(bytesWithNullTerminator <= CameraVendorConst.INIT_DEVICE_NAME_BYTE_COUNT)
    }

    @Test
    fun legacyInitFallsBackWhenConnectedDeviceNameIsMissingOrTooLong() {
        assertEquals("CamTransfer-6970", CameraVendorPtpIdentityPolicy.legacyInitFriendlyName(null))
        assertEquals("CamTransfer-6970", CameraVendorPtpIdentityPolicy.legacyInitFriendlyName("x".repeat(28)))
    }
}
