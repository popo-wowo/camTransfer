package com.camtransfer.service

import android.content.Context
import android.provider.MediaStore
import com.camtransfer.model.CameraFile
import java.nio.charset.StandardCharsets
import java.util.Base64

private const val DOWNLOADED_PREFS = "camtransfer.downloaded_files"
private const val DOWNLOADED_KEYS = "downloaded_keys"
private const val INCLUDE_SAVED_MEDIA_NAMES = "include_saved_media_names"

class DownloadedFileStore(context: Context) {
    private val context = context.applicationContext
    private val prefs = context.getSharedPreferences(DOWNLOADED_PREFS, Context.MODE_PRIVATE)

    fun markDownloaded(file: CameraFile) {
        val keys = prefs.getStringSet(DOWNLOADED_KEYS, emptySet()).orEmpty().toMutableSet()
        keys.add(DownloadedFileIdentity.key(file))
        prefs.edit().putStringSet(DOWNLOADED_KEYS, keys).apply()
    }

    fun clear() {
        prefs.edit()
            .putStringSet(DOWNLOADED_KEYS, emptySet())
            .putBoolean(INCLUDE_SAVED_MEDIA_NAMES, false)
            .apply()
    }

    fun isDownloaded(file: CameraFile): Boolean =
        DownloadedFileIdentity.key(file) in downloadedKeys() || file.info.filename in savedMediaNames()

    fun downloadedFiles(files: List<CameraFile>): List<CameraFile> {
        val downloadedKeys = downloadedKeys()
        val savedNames = savedMediaNames()
        return files.filter { file ->
            DownloadedFileIdentity.key(file) in downloadedKeys || file.info.filename in savedNames
        }
    }

    private fun downloadedKeys(): Set<String> =
        prefs.getStringSet(DOWNLOADED_KEYS, emptySet()).orEmpty()

    private fun savedMediaNames(): Set<String> =
        if (prefs.getBoolean(INCLUDE_SAVED_MEDIA_NAMES, true)) {
            querySavedMediaNames(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)) +
                querySavedMediaNames(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY))
        } else {
            emptySet()
        }

    private fun querySavedMediaNames(uri: android.net.Uri): Set<String> {
        val names = mutableSetOf<String>()
        val projection = arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH,
        )
        runCatching {
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val pathIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)
                while (cursor.moveToNext()) {
                    val relativePath = cursor.getString(pathIndex).orEmpty()
                    if (relativePath.contains("CamTransfer", ignoreCase = true)) {
                        names.add(cursor.getString(nameIndex).orEmpty())
                    }
                }
            }
        }
        return names
    }
}

object DownloadedFileIdentity {
    fun key(file: CameraFile): String {
        val info = file.info
        return listOf(
            info.storageId.toString(),
            info.handle.toString(),
            info.format.toString(),
            info.compressedSize.toString(),
            encode(info.filename),
            encode(info.captureDate),
        ).joinToString("|")
    }

    private fun encode(value: String): String =
        Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(value.toByteArray(StandardCharsets.UTF_8))
}
