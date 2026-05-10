package com.camtransfer.service

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat

private const val TAG = "GalleryService"

class GalleryService(private val context: Context) {

    fun saveToGallery(info: ObjectInfo, data: ByteArray): Boolean {
        val mimeType = when (info.format) {
            PtpObjectFormat.JPEG -> "image/jpeg"
            PtpObjectFormat.CAMERA_VENDOR_RAF -> "image/x-cameraVendor-raf"
            PtpObjectFormat.MOV -> "video/quicktime"
            PtpObjectFormat.MP4 -> "video/mp4"
            else -> "application/octet-stream"
        }

        val isVideo = info.isVideo
        val collection = if (isVideo)
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

        val relativePath = if (isVideo)
            "${Environment.DIRECTORY_MOVIES}/CamTransfer"
        else
            "${Environment.DIRECTORY_PICTURES}/CamTransfer"

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, info.filename)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val resolver = context.contentResolver
        val uri = resolver.insert(collection, values) ?: run {
            Log.e(TAG, "Failed to create MediaStore entry for ${info.filename}")
            return false
        }

        resolver.openOutputStream(uri)?.use { it.write(data) }

        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)

        Log.d(TAG, "Saved ${info.filename} (${data.size} bytes) to $relativePath")
        return true
    }
}
