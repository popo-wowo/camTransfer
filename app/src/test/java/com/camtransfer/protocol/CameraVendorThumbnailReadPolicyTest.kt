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
    fun smallCameraVendorJpegPreviewDoesNotBypassStandardThumbnail() {
        assertFalse(
            CameraVendorThumbnailReadPolicy.shouldReadPartialPreviewBeforeStandardThumbnail(
                objectInfo(format = PtpObjectFormat.JPEG, compressedSize = 167_936),
            ),
        )
    }

    @Test
    fun vendorExtensionThumbnailIsNotPreferredForListedGalleryHandles() {
        assertFalse(CameraVendorThumbnailReadPolicy.shouldTryVendorExtensionThumbnailFirst())
    }

    @Test
    fun primesObjectContextBeforePartialFallbackOnly() {
        assertTrue(CameraVendorThumbnailReadPolicy.shouldPrimeObjectContextBeforePartialFallback())
    }

    @Test
    fun smallJpegObjectsWithStandardThumbnailInfoUseStandardThumbnailFirst() {
        assertFalse(
            CameraVendorThumbnailReadPolicy.shouldReadPartialPreviewBeforeStandardThumbnail(
                objectInfo(
                    format = PtpObjectFormat.JPEG,
                    compressedSize = 167_936,
                    thumbPixWidth = 640,
                    thumbPixHeight = 480,
                ),
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

    @Test
    fun rejectsIncompleteJpegPartialPreviewData() {
        assertTrue(
            CameraVendorThumbnailReadPolicy.shouldRejectIncompletePartialPreview(
                byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01, 0x02),
            )
        )
        assertFalse(
            CameraVendorThumbnailReadPolicy.shouldRejectIncompletePartialPreview(
                byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01, 0x02, 0xFF.toByte(), 0xD9.toByte()),
            )
        )
        assertFalse(
            CameraVendorThumbnailReadPolicy.shouldRejectIncompletePartialPreview(
                byteArrayOf(0x00, 0x01, 0x02),
            )
        )
        assertTrue(
            CameraVendorThumbnailReadPolicy.shouldRejectIncompletePartialPreview(
                byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + ByteArray(128 * 1024) { 0x01 },
            )
        )
    }

    private fun objectInfo(
        format: Int,
        compressedSize: Int,
        thumbPixWidth: Int = 0,
        thumbPixHeight: Int = 0,
    ): ObjectInfo = ObjectInfo(
        handle = 1,
        storageId = 0,
        format = format,
        compressedSize = compressedSize,
        thumbFormat = PtpObjectFormat.JPEG,
        thumbCompressedSize = 0,
        thumbPixWidth = thumbPixWidth,
        thumbPixHeight = thumbPixHeight,
        imagePixWidth = 0,
        imagePixHeight = 0,
        parentObject = 0,
        filename = "DSCF0001.JPG",
        captureDate = "",
    )
}
