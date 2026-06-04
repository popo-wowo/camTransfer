package com.camtransfer.wifi

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraCurrentWifiMatchPolicyTest {
    @Test
    fun quotedCurrentSsidMatchesCameraSsid() {
        assertTrue(
            CameraCurrentWifiMatchPolicy.matches(
                currentSsid = "\"FUJIFILM-X-T5-003B\"",
                currentBssid = "AA:BB:CC:DD:EE:FF",
                configuration = CameraVendorWifiNetworkConfiguration(
                    ssid = "FUJIFILM-X-T5-003B",
                    passphrase = "12345678",
                    isHidden = false,
                    bssid = "aa:bb:cc:dd:ee:ff",
                ),
            )
        )
    }

    @Test
    fun unknownSsidDoesNotMatchCameraSsid() {
        assertFalse(
            CameraCurrentWifiMatchPolicy.matches(
                currentSsid = "<unknown ssid>",
                currentBssid = "aa:bb:cc:dd:ee:ff",
                configuration = CameraVendorWifiNetworkConfiguration(
                    ssid = "FUJIFILM-X-T5-003B",
                    passphrase = "12345678",
                    isHidden = false,
                    bssid = "aa:bb:cc:dd:ee:ff",
                ),
            )
        )
    }

    @Test
    fun mismatchedBssidRejectsNetworkWhenCameraBssidIsKnown() {
        assertFalse(
            CameraCurrentWifiMatchPolicy.matches(
                currentSsid = "FUJIFILM-X-T5-003B",
                currentBssid = "11:22:33:44:55:66",
                configuration = CameraVendorWifiNetworkConfiguration(
                    ssid = "FUJIFILM-X-T5-003B",
                    passphrase = "12345678",
                    isHidden = false,
                    bssid = "aa:bb:cc:dd:ee:ff",
                ),
            )
        )
    }
}
