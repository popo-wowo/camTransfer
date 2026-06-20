package com.camtransfer.wifi

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorWifiNetworkConfigurationPolicyTest {
    @Test
    fun exactBleWifiConfigurationUsesOnlyFreshOfficialCandidate() {
        val candidates = CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = "X-T5",
            serialNumber = "221019F1932011003B",
            preferredWifiNetwork = CameraVendorWifiNetworkConfigurationPolicy.referenceAppConfiguration(
                ssid = "FUJIFILM-X-T5-003B",
                passphrase = "12345678",
                macAddress = "AABBCCDDEEFF",
            ),
        )

        assertEquals(
            listOf(
                CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-003B", "12345678", false, "aa:bb:cc:dd:ee:ff"),
            ),
            candidates,
        )
    }

    @Test
    fun referenceAppWifiConfigurationUsesVisibleExactRequestLikeOfficialApp() {
        assertEquals(
            CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-003B", "12345678", false),
            CameraVendorWifiNetworkConfigurationPolicy.referenceAppConfiguration(
                ssid = " FUJIFILM-X-T5-003B ",
                passphrase = "12345678",
            ),
        )
    }

    @Test
    fun referenceAppWifiConfigurationNormalizesBssidLikeOfficialApp() {
        assertEquals(
            "aa:bb:cc:dd:ee:ff",
            CameraVendorWifiNetworkConfigurationPolicy.referenceAppConfiguration(
                ssid = "FUJIFILM-X-T5-003B",
                passphrase = "12345678",
                macAddress = "AA-BB-CC-DD-EE-FF",
            ).bssid,
        )
        assertEquals(
            null,
            CameraVendorWifiNetworkConfigurationPolicy.referenceAppConfiguration(
                ssid = "FUJIFILM-X-T5-003B",
                passphrase = "12345678",
                macAddress = "not-a-mac",
            ).bssid,
        )
    }

    @Test
    fun missingReferenceAppWifiConfigurationDoesNotGenerateGuessedCandidates() {
        val candidates = CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = "X-T5-003B",
            serialNumber = "221019F1932011003B",
            preferredWifiNetwork = null,
        )

        assertEquals(emptyList<CameraVendorWifiNetworkConfiguration>(), candidates)
    }

    @Test
    fun missingReferenceAppWifiConfigurationWithCameraNameStillStopsInsteadOfGuessing() {
        val candidates = CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = "X-T5",
            serialNumber = "221019F1932011003B",
            preferredWifiNetwork = null,
        )

        assertEquals(emptyList<CameraVendorWifiNetworkConfiguration>(), candidates)
    }
}
