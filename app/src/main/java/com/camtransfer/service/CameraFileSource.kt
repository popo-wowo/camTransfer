package com.camtransfer.service

import android.content.Context
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferDownloadMode
import java.io.OutputStream

interface CameraFileSource {
    val context: Context
    val displayName: String? get() = null

    suspend fun fastInitialFiles(): List<CameraFile> = emptyList()

    suspend fun listFiles(): List<CameraFile>

    suspend fun getThumbnail(handle: Int): ByteArray

    suspend fun getThumbnailWithInfo(handle: Int): CameraThumbnail =
        CameraThumbnail(data = getThumbnail(handle))

    suspend fun resolveFile(handle: Int): CameraFile? = null

    suspend fun resolveAdditionalFiles(knownHandles: List<Int>): List<CameraFile> = emptyList()

    suspend fun resolveForwardFiles(knownHandles: List<Int>): List<CameraFile> = emptyList()

    fun hiddenProbeCandidates(knownHandles: List<Int>): List<Int> = emptyList()

    suspend fun getPreviewImage(handle: Int): ByteArray = getFile(handle)

    suspend fun getFile(
        handle: Int,
        downloadMode: TransferDownloadMode = TransferDownloadMode.ORIGINAL,
    ): ByteArray

    suspend fun writeFile(
        handle: Int,
        downloadMode: TransferDownloadMode = TransferDownloadMode.ORIGINAL,
        output: OutputStream,
    ): Long {
        val data = getFile(handle, downloadMode)
        output.write(data)
        return data.size.toLong()
    }

    suspend fun disconnect()
}

data class CameraThumbnail(
    val data: ByteArray,
    val file: CameraFile? = null,
)
