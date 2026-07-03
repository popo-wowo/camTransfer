package com.camtransfer.service

import android.content.Context
import android.provider.MediaStore
import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import java.nio.charset.StandardCharsets
import java.util.Base64

private const val DOWNLOADED_PREFS = "camtransfer.downloaded_files"
private const val DOWNLOADED_KEYS = "downloaded_keys"
private const val DOWNLOADED_RECORDS = "downloaded_records"
private const val INCLUDE_SAVED_MEDIA_NAMES = "include_saved_media_names"

class DownloadedFileStore(context: Context) {
    private val context = context.applicationContext
    private val prefs = context.getSharedPreferences(DOWNLOADED_PREFS, Context.MODE_PRIVATE)
    private val downloadFolderSettingsStore = DownloadFolderSettingsStore(this.context)

    fun markDownloaded(file: CameraFile) {
        val keys = prefs.getStringSet(DOWNLOADED_KEYS, emptySet()).orEmpty().toMutableSet()
        keys.add(DownloadedFileIdentity.key(file))
        val records = prefs.getStringSet(DOWNLOADED_RECORDS, emptySet()).orEmpty().toMutableSet()
        records.removeAll { record ->
            runCatching { DownloadedFileRecordCodec.decode(record).info.handle == file.info.handle }
                .getOrDefault(false)
        }
        records.add(DownloadedFileRecordCodec.encode(file))
        prefs.edit()
            .putStringSet(DOWNLOADED_KEYS, keys)
            .putStringSet(DOWNLOADED_RECORDS, records)
            .apply()
    }

    fun clear() {
        prefs.edit()
            .putStringSet(DOWNLOADED_KEYS, emptySet())
            .putStringSet(DOWNLOADED_RECORDS, emptySet())
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

    fun downloadedHistory(): List<CameraFile> =
        prefs.getStringSet(DOWNLOADED_RECORDS, emptySet())
            .orEmpty()
            .mapNotNull { record -> runCatching { DownloadedFileRecordCodec.decode(record) }.getOrNull() }
            .sortedWith(compareByDescending<CameraFile> { it.info.captureDate }.thenByDescending { it.info.handle })

    private fun downloadedKeys(): Set<String> =
        prefs.getStringSet(DOWNLOADED_KEYS, emptySet()).orEmpty()

    private fun savedMediaNames(): Set<String> {
        if (!prefs.getBoolean(INCLUDE_SAVED_MEDIA_NAMES, true)) return emptySet()
        val settings = downloadFolderSettingsStore.load()
        if (!DownloadFolderPathPolicy.shouldShowRuleOptions(settings)) return emptySet()
        val managedRootFolderName = settings.rootFolderName
        return querySavedMediaNames(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            managedRootFolderName,
        ) +
            querySavedMediaNames(
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                managedRootFolderName,
            )
    }

    private fun querySavedMediaNames(
        uri: android.net.Uri,
        managedRootFolderName: String,
    ): Set<String> {
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
                    if (DownloadedFileMediaPathPolicy.matchesManagedFolder(relativePath, managedRootFolderName)) {
                        names.add(cursor.getString(nameIndex).orEmpty())
                    }
                }
            }
        }
        return names
    }
}

internal object DownloadedFileMediaPathPolicy {
    fun matchesManagedFolder(relativePath: String, rootFolderName: String): Boolean {
        val normalizedRoot = DownloadFolderPathPolicy.normalizedRootFolderName(rootFolderName)
        return relativePath
            .trim()
            .contains("/$normalizedRoot/", ignoreCase = true) ||
            relativePath.trim().endsWith("/$normalizedRoot", ignoreCase = true)
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

object DownloadedFileRecordCodec {
    fun encode(file: CameraFile): String {
        val info = file.info
        return listOf(
            info.handle.toString(),
            info.storageId.toString(),
            info.format.toString(),
            info.compressedSize.toString(),
            info.thumbFormat.toString(),
            info.thumbCompressedSize.toString(),
            info.thumbPixWidth.toString(),
            info.thumbPixHeight.toString(),
            info.imagePixWidth.toString(),
            info.imagePixHeight.toString(),
            info.parentObject.toString(),
            encodeText(info.filename),
            encodeText(info.captureDate),
            info.orientation?.toString().orEmpty(),
            file.thumbnail?.let { encodeBytes(it) }.orEmpty(),
        ).joinToString("|")
    }

    fun decode(record: String): CameraFile {
        val parts = record.split("|")
        require(parts.size >= 14) { "Invalid downloaded record" }
        return CameraFile(
            ObjectInfo(
                handle = parts[0].toInt(),
                storageId = parts[1].toInt(),
                format = parts[2].toInt(),
                compressedSize = parts[3].toInt(),
                thumbFormat = parts[4].toInt(),
                thumbCompressedSize = parts[5].toInt(),
                thumbPixWidth = parts[6].toInt(),
                thumbPixHeight = parts[7].toInt(),
                imagePixWidth = parts[8].toInt(),
                imagePixHeight = parts[9].toInt(),
                parentObject = parts[10].toInt(),
                filename = decodeText(parts[11]),
                captureDate = decodeText(parts[12]),
                orientation = parts[13].takeIf { it.isNotBlank() }?.toInt(),
            ),
            thumbnail = parts.getOrNull(14)
                ?.takeIf { it.isNotBlank() }
                ?.let(::decodeBytes),
        )
    }

    private fun encodeText(value: String): String =
        Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(value.toByteArray(StandardCharsets.UTF_8))

    private fun decodeText(value: String): String =
        String(Base64.getUrlDecoder().decode(value), StandardCharsets.UTF_8)

    private fun encodeBytes(value: ByteArray): String =
        Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(value)

    private fun decodeBytes(value: String): ByteArray =
        Base64.getUrlDecoder().decode(value)
}
