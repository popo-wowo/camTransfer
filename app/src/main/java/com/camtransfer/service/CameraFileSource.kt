package com.camtransfer.service

import android.content.Context
import com.camtransfer.model.CameraFile

interface CameraFileSource {
    val context: Context

    suspend fun fastInitialFiles(): List<CameraFile> = emptyList()

    suspend fun listFiles(): List<CameraFile>

    suspend fun getThumbnail(handle: Int): ByteArray

    suspend fun getFile(handle: Int): ByteArray

    suspend fun disconnect()
}
