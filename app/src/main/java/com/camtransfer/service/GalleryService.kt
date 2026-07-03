package com.camtransfer.service

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import java.io.OutputStream

private const val TAG = "GalleryService"

class GalleryService(
    val context: Context,
    private val cameraDisplayName: () -> String? = { null },
) {
    private val downloadFolderSettingsStore = DownloadFolderSettingsStore(context)

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
        val settings = downloadFolderSettingsStore.load()
        val mimeType = when (info.format) {
            PtpObjectFormat.JPEG -> "image/jpeg"
            PtpObjectFormat.HEIF -> "image/heif"
            PtpObjectFormat.CAMERA_VENDOR_RAF,
            PtpObjectFormat.CAMERA_VENDOR_RAF_ALT -> "image/x-cameraVendor-raf"
            PtpObjectFormat.MOV -> "video/quicktime"
            PtpObjectFormat.MP4 -> "video/mp4"
            else -> "application/octet-stream"
        }

        if (DownloadFolderPathPolicy.usesCustomTree(settings)) {
            return saveToCustomTree(
                info = info,
                mimeType = mimeType,
                treeUriString = settings.customTreeUri.orEmpty(),
                writeData = writeData,
            )
        }

        val isVideo = info.isVideo
        val collection = if (isVideo)
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

        val relativePath = DownloadFolderPathPolicy.relativePath(
            mediaRootDirectory = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES,
            settings = settings,
            cameraDisplayName = cameraDisplayName(),
            captureDate = info.captureDate,
        )

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

    private suspend fun saveToCustomTree(
        info: ObjectInfo,
        mimeType: String,
        treeUriString: String,
        writeData: suspend (OutputStream) -> Long,
    ): Boolean {
        val resolver = context.contentResolver
        val treeUri = runCatching { Uri.parse(treeUriString) }.getOrNull() ?: return false
        val treeDocumentUri = runCatching {
            DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        }.getOrNull() ?: return false
        val documentUri = DocumentsContract.createDocument(
            resolver,
            treeDocumentUri,
            mimeType,
            info.filename,
        ) ?: run {
            Log.e(TAG, "Failed to create custom tree document for ${info.filename}")
            DiagnosticLog.append(context, TAG, "Failed to create custom tree document format=${info.formatLabel}")
            return false
        }

        val bytes = try {
            val output = resolver.openOutputStream(documentUri) ?: run {
                Log.e(TAG, "Failed to open custom tree output for ${info.filename}")
                DiagnosticLog.append(context, TAG, "Failed to open custom tree output format=${info.formatLabel}")
                resolver.delete(documentUri, null, null)
                return false
            }
            try {
                writeData(output)
            } finally {
                output.close()
            }
        } catch (e: Throwable) {
            resolver.delete(documentUri, null, null)
            throw e
        }

        Log.d(TAG, "Saved ${info.filename} ($bytes bytes) to custom tree")
        DiagnosticLog.append(context, TAG, "Saved file bytes=$bytes mediaType=custom_tree")
        return true
    }
}
