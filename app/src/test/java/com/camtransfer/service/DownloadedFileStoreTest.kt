package com.camtransfer.service

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadedFileStoreTest {
    @Test
    fun identityKeyChangesWhenSameHandlePointsToDifferentPhoto() {
        val original = file(handle = 10, filename = "DSCF0010.JPG", size = 2048, captureDate = "20260531T100000")
        val sameHandleDifferentName = file(handle = 10, filename = "DSCF9010.JPG", size = 2048, captureDate = "20260531T100000")
        val sameHandleDifferentSize = file(handle = 10, filename = "DSCF0010.JPG", size = 4096, captureDate = "20260531T100000")
        val sameHandleDifferentDate = file(handle = 10, filename = "DSCF0010.JPG", size = 2048, captureDate = "20260601T100000")

        val originalKey = DownloadedFileIdentity.key(original)

        assertNotEquals(originalKey, DownloadedFileIdentity.key(sameHandleDifferentName))
        assertNotEquals(originalKey, DownloadedFileIdentity.key(sameHandleDifferentSize))
        assertNotEquals(originalKey, DownloadedFileIdentity.key(sameHandleDifferentDate))
    }

    @Test
    fun identityKeyIsStableForSamePhotoMetadata() {
        val first = file(handle = 10, filename = "DSCF0010.JPG", size = 2048, captureDate = "20260531T100000")
        val second = file(handle = 10, filename = "DSCF0010.JPG", size = 2048, captureDate = "20260531T100000")

        assertEquals(DownloadedFileIdentity.key(first), DownloadedFileIdentity.key(second))
    }

    @Test
    fun downloadedRecordRoundTripsFullFileMetadata() {
        val original = file(handle = 18, filename = "DSCF0018.JPG", size = 3_456_789, captureDate = "20260616T220000")

        val restored = DownloadedFileRecordCodec.decode(
            DownloadedFileRecordCodec.encode(original)
        )

        assertEquals(original.info, restored.info)
    }

    @Test
    fun downloadedRecordRoundTripsThumbnailBytes() {
        val thumbnail = byteArrayOf(0x01, 0x23, 0x45, 0x67)
        val original = file(
            handle = 18,
            filename = "DSCF0018.JPG",
            size = 3_456_789,
            captureDate = "20260616T220000",
            thumbnail = thumbnail,
        )

        val restored = DownloadedFileRecordCodec.decode(
            DownloadedFileRecordCodec.encode(original)
        )

        assertEquals(original.info, restored.info)
        assertArrayEquals(thumbnail, restored.thumbnail)
    }

    @Test
    fun downloadedRecordKeepsOldRecordsWithoutThumbnailCompatible() {
        val original = file(handle = 18, filename = "DSCF0018.JPG", size = 3_456_789, captureDate = "20260616T220000")
        val oldRecord = DownloadedFileRecordCodec.encode(original)
            .split("|")
            .take(14)
            .joinToString("|")

        val restored = DownloadedFileRecordCodec.decode(oldRecord)

        assertEquals(original.info, restored.info)
        assertNull(restored.thumbnail)
    }

    @Test
    fun savedMediaPathMatchingFollowsConfiguredRootFolderName() {
        assertTrue(DownloadedFileMediaPathPolicy.matchesManagedFolder("Pictures/My Imports/X-T5/2026-06-27/", "My Imports"))
        assertFalse(DownloadedFileMediaPathPolicy.matchesManagedFolder("Pictures/CamTransfer/X-T5/2026-06-27/", "My Imports"))
    }

    private fun file(
        handle: Int,
        filename: String,
        size: Int,
        captureDate: String,
        thumbnail: ByteArray? = null,
    ): CameraFile =
        CameraFile(
            ObjectInfo(
                handle = handle,
                storageId = 1,
                format = PtpObjectFormat.JPEG,
                compressedSize = size,
                thumbFormat = PtpObjectFormat.JPEG,
                thumbCompressedSize = 128,
                thumbPixWidth = 160,
                thumbPixHeight = 120,
                imagePixWidth = 4000,
                imagePixHeight = 3000,
                parentObject = 0,
                filename = filename,
                captureDate = captureDate,
            ),
            thumbnail = thumbnail,
        )
}
