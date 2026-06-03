package com.camtransfer.model

import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotEquals
import org.junit.Test

class CameraFileTest {
    @Test
    fun thumbnailBytesParticipateInEqualitySoStateFlowEmitsUpdates() {
        val info = ObjectInfo(
            handle = 1,
            storageId = 1,
            format = PtpObjectFormat.JPEG,
            compressedSize = 1024,
            thumbFormat = PtpObjectFormat.JPEG,
            thumbCompressedSize = 128,
            thumbPixWidth = 160,
            thumbPixHeight = 120,
            imagePixWidth = 4000,
            imagePixHeight = 3000,
            parentObject = 0,
            filename = "DSCF0001.JPG",
            captureDate = "20260513T120000",
        )

        assertNotEquals(
            CameraFile(info, thumbnail = null),
            CameraFile(info, thumbnail = byteArrayOf(0x01, 0x02)),
        )
        assertNotEquals(
            CameraFile(info, thumbnail = byteArrayOf(0x01, 0x02)),
            CameraFile(info, thumbnail = byteArrayOf(0x03, 0x04)),
        )
    }

    @Test
    fun heifFilesAreRecognizedByCommonCameraExtensionsWhenFormatCodeIsGeneric() {
        val heic = info(filename = "DSCF0002.HEIC", format = PtpObjectFormat.UNDEFINED)
        val hif = info(filename = "DSCF0003.HIF", format = PtpObjectFormat.UNDEFINED)

        assertTrue(heic.isHeif)
        assertTrue(hif.isHeif)
        assertEquals("HEIF", heic.formatLabel)
        assertEquals("HEIF", hif.formatLabel)
    }

    private fun info(
        filename: String = "DSCF0001.JPG",
        format: Int = PtpObjectFormat.JPEG,
    ) = ObjectInfo(
        handle = 1,
        storageId = 1,
        format = format,
        compressedSize = 1024,
        thumbFormat = PtpObjectFormat.JPEG,
        thumbCompressedSize = 128,
        thumbPixWidth = 160,
        thumbPixHeight = 120,
        imagePixWidth = 4000,
        imagePixHeight = 3000,
        parentObject = 0,
        filename = filename,
        captureDate = "20260513T120000",
    )
}
