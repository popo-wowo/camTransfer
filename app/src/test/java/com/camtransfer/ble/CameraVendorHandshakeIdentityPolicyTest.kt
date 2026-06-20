package com.camtransfer.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorHandshakeIdentityPolicyTest {

    @Test
    fun connectedDeviceNameUsesOfficialAndroidTerminalNameFormat() {
        assertEquals(
            "Xiaomi-14-1234",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("  Xiaomi 14  ", suffix = 1234),
        )
    }

    @Test
    fun connectedDeviceNameSanitizesAndTruncatesLikeOfficialAndroidApp() {
        assertEquals(
            "Xiaomi-14-Pro-0007",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName(" Xiaomi\t14\nPro ", suffix = 7),
        )
        assertEquals(
            "Android-0007",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("   ", suffix = 7),
        )
        assertEquals(
            "Android-0007",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName(null, suffix = 7),
        )
        assertEquals(
            "${"x".repeat(19)}..-0007",
            CameraVendorHandshakeIdentityPolicy.connectedDeviceName("x".repeat(64), suffix = 7),
        )
    }

    @Test
    fun connectedDeviceNameDecisionRecordsOfficialAndroidSource() {
        val decision = CameraVendorHandshakeIdentityPolicy.connectedDeviceNameDecision("x".repeat(64), suffix = 9876)

        assertEquals("${"x".repeat(19)}..-9876", decision.name)
        assertEquals("official_android_terminal_name", decision.source)
        assertEquals(64, decision.rawLength)
    }

    @Test
    fun connectedDeviceNameReusesSavedRegistrationNameInsteadOfRegeneratingSuffix() {
        val decision = CameraVendorHandshakeIdentityPolicy.connectedDeviceNameDecision(
            preferredDeviceName = "23127PN0CC",
            suffix = 4567,
            savedRegistrationName = "23127PN0CC-1234",
        )

        assertEquals("23127PN0CC-1234", decision.name)
        assertEquals("official_android_terminal_name_saved", decision.source)
    }

}
