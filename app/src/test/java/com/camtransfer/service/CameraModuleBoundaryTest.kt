package com.camtransfer.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CameraModuleBoundaryTest {
    @Test
    fun gallerySourceDoesNotDependOnBleWifiOrPairingModules() {
        val source = sourceFile("service/gallery/PtpCameraGallerySource.kt").readText()

        assertFalse(source.contains("com.camtransfer.ble"))
        assertFalse(source.contains("com.camtransfer.wifi"))
        assertFalse(source.contains("CameraVendorPairedCameraStore"))
        assertTrue(source.contains("CameraFileSource"))
    }

    @Test
    fun downloadServiceDependsOnCameraFileSourceInsteadOfConnectionDetails() {
        val source = sourceFile("service/TransferService.kt").readText()

        assertTrue(source.contains("private val cameraSource: CameraFileSource"))
        assertFalse(source.contains("com.camtransfer.ble"))
        assertFalse(source.contains("com.camtransfer.wifi"))
        assertFalse(source.contains("PtpConnection"))
        assertFalse(source.contains("CameraVendorBleHandshake"))
    }

    private fun sourceFile(path: String): File =
        listOf(
            File("src/main/java/com/camtransfer/$path"),
            File("app/src/main/java/com/camtransfer/$path"),
        ).first { it.exists() }
}
