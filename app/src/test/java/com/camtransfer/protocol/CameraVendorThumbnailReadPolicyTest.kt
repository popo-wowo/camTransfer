package com.camtransfer.protocol

import com.camtransfer.model.ObjectInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorThumbnailReadPolicyTest {
    @Test
    fun primesObjectContextBeforeStandardThumbnailRead() {
        assertTrue(CameraVendorThumbnailReadPolicy.shouldPrimeObjectContextBeforeStandardThumbnail())
    }

    @Test
    fun standardThumbnailReadTimeoutIsShorterThanSocketDefault() {
        assertEquals(3_000, CameraVendorThumbnailReadPolicy.STANDARD_THUMB_TIMEOUT_MS)
    }

    @Test
    fun smallJpegPreviewObjectsUsePartialPreviewBeforeStandardThumbnail() {
        assertTrue(
            CameraVendorThumbnailReadPolicy.shouldReadPartialPreviewBeforeStandardThumbnail(
                objectInfo(format = PtpObjectFormat.JPEG, compressedSize = 167_936),
            ),
        )
    }

    @Test
    fun rawObjectsKeepStandardThumbnailFirst() {
        assertFalse(
            CameraVendorThumbnailReadPolicy.shouldReadPartialPreviewBeforeStandardThumbnail(
                objectInfo(format = PtpObjectFormat.CAMERA_VENDOR_RAF_ALT, compressedSize = 84_658_176),
            ),
        )
    }

    private fun objectInfo(format: Int, compressedSize: Int): ObjectInfo = ObjectInfo(
        handle = 1,
        storageId = 0,
        format = format,
        compressedSize = compressedSize,
        thumbFormat = PtpObjectFormat.JPEG,
        thumbCompressedSize = 0,
        thumbPixWidth = 0,
        thumbPixHeight = 0,
        imagePixWidth = 0,
        imagePixHeight = 0,
        parentObject = 0,
        filename = "DSCF0001.JPG",
        captureDate = "",
    )
}
