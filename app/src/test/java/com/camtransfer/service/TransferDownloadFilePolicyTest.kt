package com.camtransfer.service

import com.camtransfer.model.CameraFile
import com.camtransfer.model.CameraFileFormatHint
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferDownloadMode
import com.camtransfer.model.TransferItem
import com.camtransfer.protocol.PtpObjectFormat
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.SocketException

class TransferDownloadFilePolicyTest {
    @Test
    fun transferItemKeepsDownloadModeSelectedAtEnqueueTime() {
        val queuedFile = cameraFile(
            handle = 18,
            filename = "DSCF0018.JPG",
            compressedSize = 2048,
        )

        val item = TransferItem(
            file = queuedFile,
            downloadMode = TransferDownloadMode.ORIGINAL,
        )

        assertEquals(TransferDownloadMode.ORIGINAL, item.downloadMode)
    }

    @Test
    fun pendingDownloadModeKeepsRawOriginalEvenWhenCompressedModeIsSelected() {
        val jpg = TransferItem(
            file = cameraFile(handle = 1, filename = "DSCF0001.JPG", compressedSize = 2048),
            downloadMode = TransferDownloadMode.ORIGINAL,
        )
        val raw = TransferItem(
            file = cameraFile(
                handle = 2,
                filename = "DSCF0001.RAF",
                compressedSize = 85_000_000,
                format = PtpObjectFormat.CAMERA_VENDOR_RAF,
            ),
            downloadMode = TransferDownloadMode.ORIGINAL,
        )

        val updated = TransferQueueDownloadModePolicy.applyPendingMode(
            items = listOf(jpg, raw),
            selectedMode = TransferDownloadMode.COMPRESSED,
        )

        assertEquals(TransferDownloadMode.COMPRESSED, updated[0].downloadMode)
        assertEquals(TransferDownloadMode.ORIGINAL, updated[1].downloadMode)
    }

    @Test
    fun pendingDownloadModeKeepsRawOnlyCandidateOriginalBeforeMetadataResolves() {
        val rawCandidate = TransferItem(
            file = cameraFile(
                handle = 1805,
                filename = "0x0000070D",
                compressedSize = 0,
                format = PtpObjectFormat.UNDEFINED,
                formatHints = setOf(CameraFileFormatHint.RAW),
            ),
            downloadMode = TransferDownloadMode.COMPRESSED,
        )

        val updated = TransferQueueDownloadModePolicy.applyPendingMode(
            items = listOf(rawCandidate),
            selectedMode = TransferDownloadMode.COMPRESSED,
        )

        assertEquals(TransferDownloadMode.ORIGINAL, updated.single().downloadMode)
    }

    @Test
    fun removePendingItemsLeavesActiveAndCompletedItemsUntouched() {
        val pending = TransferItem(file = cameraFile(handle = 1, filename = "DSCF0001.JPG", compressedSize = 2048))
        val downloading = TransferItem(
            file = cameraFile(handle = 2, filename = "DSCF0002.JPG", compressedSize = 2048),
            state = com.camtransfer.model.TransferState.DOWNLOADING,
        )
        val done = TransferItem(
            file = cameraFile(handle = 3, filename = "DSCF0003.JPG", compressedSize = 2048),
            state = com.camtransfer.model.TransferState.DONE,
        )

        val updated = TransferQueueDownloadModePolicy.removePendingItems(
            items = listOf(pending, downloading, done),
            handles = setOf(1, 2, 3),
        )

        assertEquals(listOf(2, 3), updated.map { it.file.info.handle })
    }

    @Test
    fun pausePolicyMarksActiveAndPendingItemsPaused() {
        val pending = TransferItem(file = cameraFile(handle = 1, filename = "DSCF0001.JPG", compressedSize = 2048))
        val downloading = TransferItem(
            file = cameraFile(handle = 2, filename = "DSCF0002.JPG", compressedSize = 2048),
            state = com.camtransfer.model.TransferState.DOWNLOADING,
            progress = 0.3f,
        )
        val saving = TransferItem(
            file = cameraFile(handle = 3, filename = "DSCF0003.JPG", compressedSize = 2048),
            state = com.camtransfer.model.TransferState.SAVING,
            progress = 0.9f,
        )
        val done = TransferItem(
            file = cameraFile(handle = 4, filename = "DSCF0004.JPG", compressedSize = 2048),
            state = com.camtransfer.model.TransferState.DONE,
            progress = 1f,
        )

        val paused = TransferPausePolicy.markActiveAndPendingPaused(listOf(pending, downloading, saving, done))

        assertEquals(com.camtransfer.model.TransferState.ERROR, paused[0].state)
        assertEquals(com.camtransfer.model.TransferState.ERROR, paused[1].state)
        assertEquals(com.camtransfer.model.TransferState.ERROR, paused[2].state)
        assertEquals(com.camtransfer.model.TransferState.DONE, paused[3].state)
        assertEquals(TransferPausePolicy.PAUSED_MESSAGE, paused[0].error)
        assertEquals(TransferPausePolicy.PAUSED_MESSAGE, paused[1].error)
        assertEquals(TransferPausePolicy.PAUSED_MESSAGE, paused[2].error)
    }

    @Test
    fun transferCancellationIsPropagatedInsteadOfHandledAsDownloadFailure() {
        assertTrue(TransferCancellationPolicy.shouldPropagate(CancellationException("pause")))
        assertFalse(TransferCancellationPolicy.shouldPropagate(SocketException("Socket is closed")))
    }

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

    @Test
    fun stopsRemainingQueueWhenCameraConnectionIsLost() {
        val current = listOf(
            TransferItem(file = cameraFile(handle = 1, filename = "DSCF0001.RAF", compressedSize = 85_000_000), state = com.camtransfer.model.TransferState.ERROR),
            TransferItem(file = cameraFile(handle = 2, filename = "DSCF0002.JPG", compressedSize = 1024)),
            TransferItem(file = cameraFile(handle = 3, filename = "DSCF0003.JPG", compressedSize = 1024)),
        )

        assertTrue(TransferFailurePolicy.shouldStopQueueAfterFailure(SocketException("Socket is closed")))
        assertTrue(TransferFailurePolicy.shouldStopQueueAfterFailure(IllegalStateException("Not connected to camera")))
        assertFalse(TransferFailurePolicy.shouldStopQueueAfterFailure(IllegalArgumentException("保存失败")))

        val stopped = TransferFailurePolicy.markPendingAfterFatalFailure(
            items = current,
            error = "相机连接已断开，请重新进入相册后重试",
        )

        assertEquals(com.camtransfer.model.TransferState.ERROR, stopped[1].state)
        assertEquals(com.camtransfer.model.TransferState.ERROR, stopped[2].state)
        assertEquals("相机连接已断开，请重新进入相册后重试", stopped[1].error)
        assertEquals("相机连接已断开，请重新进入相册后重试", stopped[2].error)
    }

    @Test
    fun streamsVideosAndLargeFilesInsteadOfHoldingWholeDownloadInMemory() {
        assertTrue(
            TransferDownloadFilePolicy.shouldStreamDownload(
                cameraFile(
                    handle = 54,
                    filename = "DSCF0054.MOV",
                    compressedSize = 243_269_040,
                    format = PtpObjectFormat.MOV,
                )
            )
        )
        assertTrue(
            TransferDownloadFilePolicy.shouldStreamDownload(
                cameraFile(
                    handle = 55,
                    filename = "DSCF0055.JPG",
                    compressedSize = 96_000_000,
                    format = PtpObjectFormat.JPEG,
                )
            )
        )
        assertFalse(
            TransferDownloadFilePolicy.shouldStreamDownload(
                cameraFile(
                    handle = 56,
                    filename = "DSCF0056.JPG",
                    compressedSize = 167_936,
                    format = PtpObjectFormat.JPEG,
                )
            )
        )
    }

    private fun cameraFile(
        handle: Int,
        filename: String,
        compressedSize: Int,
        thumbnail: ByteArray? = null,
        format: Int = PtpObjectFormat.JPEG,
        formatHints: Set<CameraFileFormatHint> = emptySet(),
    ): CameraFile =
        CameraFile(
            info = ObjectInfo(
                handle = handle,
                storageId = 1,
                format = format,
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
            formatHints = formatHints,
        )
}
