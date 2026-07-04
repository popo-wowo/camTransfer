package com.camtransfer.protocol

import com.camtransfer.model.ObjectInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorThumbnailReadPolicyTest {
    @Test
    fun standardThumbnailReadDoesNotPrimeCurrentImageContext() {
        assertFalse(CameraVendorThumbnailReadPolicy.shouldPrimeObjectContextBeforeStandardThumbnail())
    }

    @Test
    fun standardThumbnailReadStillReadsStandardObjectInfo() {
        assertTrue(CameraVendorThumbnailReadPolicy.shouldReadStandardObjectInfoBeforeStandardThumbnail())
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
    fun doesNotPrimeObjectContextForDisabledPartialFallback() {
        assertFalse(CameraVendorThumbnailReadPolicy.shouldPrimeObjectContextBeforePartialFallback())
    }

    @Test
    fun partialObjectIsNotUsedAsThumbnailFallback() {
        assertFalse(CameraVendorThumbnailReadPolicy.shouldReadPartialPreviewAsThumbnailFallback())
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
    fun smallJpegAndHeifCompressedObjectsCanBeUsedForFullScreenPreview() {
        assertTrue(
            CameraVendorPreviewImageReadPolicy.shouldReadCompressedPreview(
                objectInfo(
                    format = PtpObjectFormat.JPEG,
                    compressedSize = 167_936,
                    thumbPixWidth = 640,
                    thumbPixHeight = 480,
                ),
            ),
        )
        assertTrue(
            CameraVendorPreviewImageReadPolicy.shouldReadCompressedPreview(
                objectInfo(format = PtpObjectFormat.HEIF, compressedSize = 167_936),
            ),
        )
        assertFalse(
            CameraVendorPreviewImageReadPolicy.shouldReadCompressedPreview(
                objectInfo(format = PtpObjectFormat.CAMERA_VENDOR_RAF_ALT, compressedSize = 84_658_176),
            ),
        )
        assertFalse(
            CameraVendorPreviewImageReadPolicy.shouldReadCompressedPreview(
                objectInfo(format = PtpObjectFormat.JPEG, compressedSize = 0),
            ),
        )
    }

    @Test
    fun fullScreenPreviewUsesOfficialForceCompressedModeAndCanReadMultiMegabytePreview() {
        val prepare = CameraVendorPreviewImageReadPolicy.prepareProperty()
        val reset = CameraVendorPreviewImageReadPolicy.resetProperty(prepare)
        val twoMegabytePreview = objectInfo(
            format = PtpObjectFormat.JPEG,
            compressedSize = 2 * 1024 * 1024,
        )

        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, prepare.code)
        assertEquals(1, prepare.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, prepare.width)
        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, reset.code)
        assertEquals(0, reset.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, reset.width)
        assertTrue(CameraVendorPreviewImageReadPolicy.shouldReadCompressedPreview(twoMegabytePreview))
        assertEquals(
            twoMegabytePreview.compressedSize,
            CameraVendorPreviewImageReadPolicy.readSize(twoMegabytePreview),
        )
    }

    @Test
    fun fullScreenPreviewRejectsSuspiciouslyLargeCompressedPreviewSize() {
        val oversized = objectInfo(
            format = PtpObjectFormat.JPEG,
            compressedSize = CameraVendorPreviewImageReadPolicy.MAX_SCREEN_PREVIEW_BYTES + 1,
        )

        assertFalse(CameraVendorPreviewImageReadPolicy.shouldReadCompressedPreview(oversized))
        assertEquals(null, CameraVendorPreviewImageReadPolicy.readSize(oversized))
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

    @Test
    fun fullScreenPreviewRejectsObviouslyIncompleteJpegBeforeCaching() {
        val incompleteJpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01, 0x02)
        val completeJpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01, 0x02, 0xFF.toByte(), 0xD9.toByte())
        val largeCameraPreviewWithoutEoi = byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + ByteArray(256 * 1024) { 0x01 }

        assertEquals(
            "Preview image missing JPEG EOI",
            CameraVendorPreviewImageReadPolicy.validationFailure(incompleteJpeg),
        )
        assertEquals(null, CameraVendorPreviewImageReadPolicy.validationFailure(completeJpeg))
        assertEquals(null, CameraVendorPreviewImageReadPolicy.validationFailure(largeCameraPreviewWithoutEoi))
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
