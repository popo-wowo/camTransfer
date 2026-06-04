package com.camtransfer.wifi

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorWifiNetworkConfigurationPolicyTest {
    @Test
    fun exactBleWifiConfigurationDoesNotAddGuessedCandidates() {
        val candidates = CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = "X-T5",
            serialNumber = "221019F1932011003B",
            preferredWifiNetwork = CameraVendorWifiNetworkConfigurationPolicy.referenceAppConfiguration(
                ssid = "FUJIFILM-X-T5-003B",
                passphrase = "12345678",
            ),
        )

        assertEquals(
            listOf(
                CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-003B", "12345678", true),
            ),
            candidates,
        )
    }

    @Test
    fun referenceAppWifiConfigurationUsesHiddenRequestBecauseVisibleSpecifierTimesOutOnDevice() {
        assertEquals(
            CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-003B", "12345678", true),
            CameraVendorWifiNetworkConfigurationPolicy.referenceAppConfiguration(
                ssid = " FUJIFILM-X-T5-003B ",
                passphrase = "12345678",
            ),
        )
    }

    @Test
    fun doesNotDuplicateSuffixedDeviceName() {
        val candidates = CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = "X-T5-003B",
            serialNumber = "221019F1932011003B",
            preferredWifiNetwork = null,
        )

        assertEquals(
            listOf(
                CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-003B", "00000000", false),
                CameraVendorWifiNetworkConfiguration("X-T5-003B", "00000000", false),
            ),
            candidates,
        )
    }

    @Test
    fun fallbackUsesFujifilmSuffixedSsidBeforeCameraName() {
        val candidates = CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = "X-T5",
            serialNumber = "221019F1932011003B",
            preferredWifiNetwork = null,
        )

        assertEquals(
            listOf(
                CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-003B", "00000000", false),
                CameraVendorWifiNetworkConfiguration("X-T5-003B", "00000000", false),
                CameraVendorWifiNetworkConfiguration("X-T5", "00000000", false),
            ),
            candidates,
        )
    }
}
