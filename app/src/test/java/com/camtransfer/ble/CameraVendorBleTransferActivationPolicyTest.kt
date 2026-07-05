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
    fun launchingApStateDoesNotAllowWifiHandoffAfterWaitWindow() {
        val launching = byteArrayOf(0x00.toByte(), 0x80.toByte())

        assertFalse(CameraVendorBleTransferActivationPolicy.isReadyToJoinWifi(launching))
        assertTrue(CameraVendorBleTransferActivationPolicy.isApLaunchInProgress(launching))
        assertFalse(
            CameraVendorBleTransferActivationPolicy.shouldProceedToWifiAfterReadyWait(
                lastApState = launching,
            )
        )
        assertFalse(
            CameraVendorBleTransferActivationPolicy.shouldProceedToWifiAfterReadyWait(
                lastApState = null,
            )
        )
    }

    @Test
    fun officialImportImageWaitsForApReadyBeforeWifiHandoff() {
        assertFalse(CameraVendorBleTransferActivationPolicy.shouldFastHandoffAfterCommandWrites())
        assertEquals(12_000L, CameraVendorBleTransferActivationPolicy.AP_READY_TIMEOUT_MS)
        assertEquals(250L, CameraVendorBleTransferActivationPolicy.AP_READY_POLL_INTERVAL_MS)
        assertEquals(1_000L, CameraVendorBleTransferActivationPolicy.AP_READY_READ_TIMEOUT_MS)
        assertTrue(CameraVendorBleTransferActivationPolicy.shouldActivelyDisconnectBluetoothBeforeWifi())
        assertEquals(500L, CameraVendorBleTransferActivationPolicy.BLUETOOTH_RELEASE_DELAY_MS)
    }

    @Test
    fun officialImportImageLaunchRequestUsesImportImageFunction() {
        assertTrue(
            CameraVendorBleTransferActivationPolicy.importImageLaunchRequestPayload()
                .contentEquals(byteArrayOf(0x03, 0x00))
        )
        assertEquals("0300", CameraVendorBleTransferActivationPolicy.importImageLaunchRequestHex())
    }

    @Test
    fun galleryActivationResizePayloadMatchesDownloadPreference() {
        assertTrue(CameraVendorBleTransferActivationPolicy.defaultPreferCompressedDownloads())
        assertTrue(
            CameraVendorBleTransferActivationPolicy.galleryActivationResizePayload(preferCompressedDownloads = true)
                .contentEquals(byteArrayOf(0x01))
        )
        assertTrue(
            CameraVendorBleTransferActivationPolicy.galleryActivationResizePayload(preferCompressedDownloads = false)
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
