package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPtpIdentityPolicyTest {

    @Test
    fun legacyInitUsesConnectedDeviceNameWhenItFitsWireField() {
        assertEquals(
            "iPhone-6970",
            CameraVendorPtpIdentityPolicy.legacyInitFriendlyName("iPhone-6970"),
        )
    }

    @Test
    fun legacyInitFriendlyNameFitsFixedWireField() {
        val bytesWithNullTerminator =
            CameraVendorPtpIdentityPolicy.legacyInitFriendlyName("iPhone-6970").toByteArray(Charsets.UTF_16LE).size + 2

        assertTrue(bytesWithNullTerminator <= CameraVendorConst.INIT_DEVICE_NAME_BYTE_COUNT)
    }

    @Test
    fun legacyInitFallsBackWhenConnectedDeviceNameIsMissingOrTooLong() {
        assertEquals("CamTransfer", CameraVendorPtpIdentityPolicy.legacyInitFriendlyName(null))
        assertEquals("CamTransfer", CameraVendorPtpIdentityPolicy.legacyInitFriendlyName("x".repeat(28)))
    }
}
