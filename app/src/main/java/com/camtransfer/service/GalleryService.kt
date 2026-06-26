package com.camtransfer.service

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import java.io.OutputStream

private const val TAG = "GalleryService"

class GalleryService(val context: Context) {

    fun saveToGallery(info: ObjectInfo, data: ByteArray): Boolean {
        return kotlinx.coroutines.runBlocking {
            saveToGalleryInternal(info) { output ->
                output.write(data)
                data.size.toLong()
            }
        }
    }

    suspend fun saveToGalleryFromStream(
        info: ObjectInfo,
        writeData: suspend (OutputStream) -> Long,
    ): Boolean = saveToGalleryInternal(info, writeData)

    private suspend fun saveToGalleryInternal(
        info: ObjectInfo,
        writeData: suspend (OutputStream) -> Long,
    ): Boolean {
        val mimeType = when (info.format) {
            PtpObjectFormat.JPEG -> "image/jpeg"
            PtpObjectFormat.HEIF -> "image/heif"
            PtpObjectFormat.CAMERA_VENDOR_RAF,
            PtpObjectFormat.CAMERA_VENDOR_RAF_ALT -> "image/x-cameraVendor-raf"
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
            DiagnosticLog.append(context, TAG, "Failed to create MediaStore entry format=${info.formatLabel}")
            return false
        }

        val bytes = try {
            val output = resolver.openOutputStream(uri) ?: run {
                Log.e(TAG, "Failed to open MediaStore output for ${info.filename}")
                DiagnosticLog.append(context, TAG, "Failed to open MediaStore output format=${info.formatLabel}")
                resolver.delete(uri, null, null)
                return false
            }
            try {
                writeData(output)
            } finally {
                output.close()
            }
        } catch (e: Throwable) {
            resolver.delete(uri, null, null)
            throw e
        }

        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)

        Log.d(TAG, "Saved ${info.filename} ($bytes bytes) to $relativePath")
        DiagnosticLog.append(context, TAG, "Saved file bytes=$bytes mediaType=${if (isVideo) "video" else "image"}")
        return true
    }
}
