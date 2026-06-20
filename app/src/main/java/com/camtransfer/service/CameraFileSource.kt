package com.camtransfer.service

import android.content.Context
import com.camtransfer.model.CameraFile

interface CameraFileSource {
    val context: Context

    suspend fun fastInitialFiles(): List<CameraFile> = emptyList()

    suspend fun listFiles(): List<CameraFile>

    suspend fun getThumbnail(handle: Int): ByteArray

    suspend fun getThumbnailWithInfo(handle: Int): CameraThumbnail =
        CameraThumbnail(data = getThumbnail(handle))

    suspend fun resolveFile(handle: Int): CameraFile? = null

    suspend fun getPreviewImage(handle: Int): ByteArray = getFile(handle)

    suspend fun getFile(handle: Int): ByteArray

    suspend fun disconnect()
}

data class CameraThumbnail(
    val data: ByteArray,
    val file: CameraFile? = null,
)
