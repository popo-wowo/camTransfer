package com.camtransfer.service

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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

    private fun file(
        handle: Int,
        filename: String,
        size: Int,
        captureDate: String,
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
            )
        )
}
