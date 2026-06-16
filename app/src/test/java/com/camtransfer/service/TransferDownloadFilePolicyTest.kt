package com.camtransfer.service

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class TransferDownloadFilePolicyTest {
    @Test
    fun usesResolvedCameraFileMetadataWhenQueuedFileIsPlaceholder() {
        val placeholderThumbnail = byteArrayOf(1, 2, 3)
        val queuedFile = cameraFile(
            handle = 1142,
            filename = "0x00000476.JPG",
            compressedSize = 0,
            thumbnail = placeholderThumbnail,
        )
        val resolvedFile = cameraFile(
            handle = 1142,
            filename = "DSCF1142.JPG",
            compressedSize = 167_936,
            thumbnail = null,
        )

        val selected = TransferDownloadFilePolicy.fileForSaveAndDownload(
            queuedFile = queuedFile,
            resolvedFile = resolvedFile,
        )

        assertEquals("DSCF1142.JPG", selected.info.filename)
        assertEquals(167_936, selected.info.compressedSize)
        assertSame(placeholderThumbnail, selected.thumbnail)
    }

    @Test
    fun keepsQueuedCameraFileWhenResolvedMetadataIsUnavailable() {
        val queuedFile = cameraFile(
            handle = 12,
            filename = "DSCF0012.JPG",
            compressedSize = 1024,
        )

        assertSame(
            queuedFile,
            TransferDownloadFilePolicy.fileForSaveAndDownload(
                queuedFile = queuedFile,
                resolvedFile = null,
            ),
        )
    }

    private fun cameraFile(
        handle: Int,
        filename: String,
        compressedSize: Int,
        thumbnail: ByteArray? = null,
    ): CameraFile =
        CameraFile(
            info = ObjectInfo(
                handle = handle,
                storageId = 1,
                format = PtpObjectFormat.JPEG,
                compressedSize = compressedSize,
                thumbFormat = PtpObjectFormat.JPEG,
                thumbCompressedSize = 128,
                thumbPixWidth = 160,
                thumbPixHeight = 120,
                imagePixWidth = 4000,
                imagePixHeight = 3000,
                parentObject = 0,
                filename = filename,
                captureDate = "20260616T214139",
            ),
            thumbnail = thumbnail,
        )
}
