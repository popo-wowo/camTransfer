package com.camtransfer.service

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertEquals
import org.junit.Test

class TransferHistoryPolicyTest {
    @Test
    fun downloadCenterShowsPersistedHistoryAndCurrentQueueWithoutDuplicates() {
        val historical = TransferItem(file = file(handle = 10, filename = "DSCF0010.JPG"), state = TransferState.DONE)
        val active = TransferItem(file = file(handle = 11, filename = "DSCF0011.JPG"), state = TransferState.DOWNLOADING)
        val sameAsHistory = TransferItem(file = file(handle = 10, filename = "DSCF0010.JPG"), state = TransferState.DONE)

        val visible = TransferHistoryPolicy.downloadCenterItems(
            historyItems = listOf(historical),
            queueItems = listOf(active, sameAsHistory),
        )

        assertEquals(listOf(11, 10), visible.map { it.file.info.handle })
        assertEquals(TransferState.DOWNLOADING, visible[0].state)
        assertEquals(TransferState.DONE, visible[1].state)
    }

    @Test
    fun gallerySyncDoesNotDropCompletedItemWhenCurrentFileIsOnlyAPlaceholder() {
        val completed = TransferItem(
            file = file(handle = 18, filename = "DSCF0018.JPG", size = 2_048),
            state = TransferState.DONE,
            progress = 1f,
        )
        val placeholder = file(handle = 18, filename = "0x00000012.JPG", size = 0)

        val synced = TransferHistoryPolicy.syncQueueWithGalleryFiles(
            currentItems = listOf(completed),
            currentFilesByHandle = mapOf(18 to placeholder),
            isDownloaded = { false },
        )

        assertEquals(1, synced.size)
        assertEquals("DSCF0018.JPG", synced.single().file.info.filename)
        assertEquals(TransferState.DONE, synced.single().state)
    }

    private fun file(
        handle: Int,
        filename: String,
        size: Int = 1024,
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
                captureDate = "20260616T220000",
            )
        )
}
