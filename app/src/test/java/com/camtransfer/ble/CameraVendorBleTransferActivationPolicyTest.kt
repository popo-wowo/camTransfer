package com.camtransfer.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorBleTransferActivationPolicyTest {

    @Test
    fun onlyReadyApStatesAllowWifiHandoff() {
        assertFalse(
            CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(
                byteArrayOf(0x00.toByte(), 0x80.toByte())
            )
        )
        assertFalse(
            CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(
                byteArrayOf(0x02.toByte(), 0x80.toByte())
            )
        )
        assertTrue(
            CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(
                byteArrayOf(0x01.toByte(), 0x80.toByte())
            )
        )
        assertTrue(
            CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(
                byteArrayOf(0x03.toByte(), 0x80.toByte())
            )
        )
    }

    @Test
    fun missingOrMalformedApStateDoesNotAllowWifiHandoff() {
        assertFalse(CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(null))
        assertFalse(CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(byteArrayOf()))
        assertFalse(CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(byteArrayOf(0x01)))
        assertFalse(
            CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(
                byteArrayOf(0x04.toByte(), 0x80.toByte())
            )
        )
    }

    @Test
    fun officialImportImageUsesFastHandoffAndDisconnectsBle() {
        assertTrue(CameraVendorBleTransferActivationPolicy.shouldFastHandoffAfterCommandWrites())
        assertTrue(CameraVendorBleTransferActivationPolicy.shouldActivelyDisconnectBluetoothBeforeWifi())
        assertEquals(500L, CameraVendorBleTransferActivationPolicy.BLUETOOTH_RELEASE_DELAY_MS)
    }

    @Test
    fun resizePayloadMatchesOriginalAndCompressedModes() {
        assertTrue(CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads())
        assertTrue(
            CameraVendorBleTransferActivationPolicy.resizePayload(preferCompressedDownloads = true)
                .contentEquals(byteArrayOf(0x01))
        )
        assertTrue(
            CameraVendorBleTransferActivationPolicy.resizePayload(preferCompressedDownloads = false)
                .contentEquals(byteArrayOf(0x00))
        )
        assertTrue(
            CameraVendorBleTransferActivationPolicy.statusText(preferCompressedDownloads = true)
                .contains("压缩")
        )
        assertTrue(
            CameraVendorBleTransferActivationPolicy.statusText(preferCompressedDownloads = false)
                .contains("原图")
        )
    }
}
