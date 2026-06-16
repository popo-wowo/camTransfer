package com.camtransfer.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorBleHandshakeModePolicyTest {
    @Test
    fun pairingAndRememberedGalleryModesRunSecureHandshake() {
        assertTrue(CameraVendorBleHandshakeMode.Pairing.shouldRunPairingHandshake)
        assertTrue(CameraVendorBleHandshakeMode.RememberedGallery.shouldRunPairingHandshake)
    }
}
