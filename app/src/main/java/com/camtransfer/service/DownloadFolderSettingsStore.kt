package com.camtransfer.service

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.time.LocalDate
import java.time.format.DateTimeFormatter

enum class DownloadFolderSaveMode {
    RULE_MEDIASTORE,
    CUSTOM_TREE,
}

data class DownloadFolderSettings(
    val saveMode: DownloadFolderSaveMode = DownloadFolderSaveMode.RULE_MEDIASTORE,
    val rootFolderName: String = DownloadFolderPathPolicy.DEFAULT_ROOT_FOLDER_NAME,
    val includeCameraName: Boolean = true,
    val includeDateFolder: Boolean = true,
    val customTreeUri: String? = null,
    val customTreeLabel: String? = null,
)

class DownloadFolderSettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun load(): DownloadFolderSettings =
        DownloadFolderSettings(
            saveMode = prefs.getString(KEY_SAVE_MODE, DownloadFolderSaveMode.RULE_MEDIASTORE.name)
                ?.let { value -> DownloadFolderSaveMode.entries.firstOrNull { it.name == value } }
                ?: DownloadFolderSaveMode.RULE_MEDIASTORE,
            rootFolderName = DownloadFolderPathPolicy.normalizedRootFolderName(
                prefs.getString(KEY_ROOT_FOLDER_NAME, DownloadFolderPathPolicy.DEFAULT_ROOT_FOLDER_NAME).orEmpty()
            ),
            includeCameraName = prefs.getBoolean(KEY_INCLUDE_CAMERA_NAME, true),
            includeDateFolder = prefs.getBoolean(KEY_INCLUDE_DATE_FOLDER, true),
            customTreeUri = prefs.getString(KEY_CUSTOM_TREE_URI, null)?.takeIf { it.isNotBlank() },
            customTreeLabel = prefs.getString(KEY_CUSTOM_TREE_LABEL, null)?.takeIf { it.isNotBlank() },
        )

    fun save(settings: DownloadFolderSettings) {
        val normalized = settings.normalized()
        prefs.edit()
            .putString(KEY_SAVE_MODE, normalized.saveMode.name)
            .putString(KEY_ROOT_FOLDER_NAME, normalized.rootFolderName)
            .putBoolean(KEY_INCLUDE_CAMERA_NAME, normalized.includeCameraName)
            .putBoolean(KEY_INCLUDE_DATE_FOLDER, normalized.includeDateFolder)
            .putString(KEY_CUSTOM_TREE_URI, normalized.customTreeUri)
            .putString(KEY_CUSTOM_TREE_LABEL, normalized.customTreeLabel)
            .apply()
    }

    private companion object {
        const val PREFS_NAME = "camtransfer.download_folder"
        const val KEY_SAVE_MODE = "save_mode"
        const val KEY_ROOT_FOLDER_NAME = "root_folder_name"
        const val KEY_INCLUDE_CAMERA_NAME = "include_camera_name"
        const val KEY_INCLUDE_DATE_FOLDER = "include_date_folder"
        const val KEY_CUSTOM_TREE_URI = "custom_tree_uri"
        const val KEY_CUSTOM_TREE_LABEL = "custom_tree_label"
    }
}

internal object DownloadFolderPathPolicy {
    const val DEFAULT_ROOT_FOLDER_NAME = "CamTransfer"
    private val CAPTURE_DATE_INPUT = DateTimeFormatter.ofPattern("yyyyMMdd")
    private val CAPTURE_DATE_OUTPUT = DateTimeFormatter.ofPattern("yyyy-MM-dd")
    private val INVALID_FOLDER_CHARS = Regex("""[\\/:*?"<>|]""")
    private val MULTIPLE_WHITESPACE = Regex("""\s+""")

    fun normalizedRootFolderName(value: String): String =
        sanitizedFolderSegment(value) ?: DEFAULT_ROOT_FOLDER_NAME

    fun usesCustomTree(settings: DownloadFolderSettings): Boolean =
        settings.saveMode == DownloadFolderSaveMode.CUSTOM_TREE && !settings.customTreeUri.isNullOrBlank()

    fun shouldShowRuleOptions(settings: DownloadFolderSettings): Boolean =
        settings.saveMode == DownloadFolderSaveMode.RULE_MEDIASTORE

    fun customFolderSummary(settings: DownloadFolderSettings): String =
        settings.customTreeLabel?.takeIf { it.isNotBlank() } ?: "未选择文件夹"

    fun sanitizedFolderSegment(value: String?): String? {
        val trimmed = value?.trim().orEmpty()
        if (trimmed.isBlank()) return null
        val sanitized = trimmed
            .replace(INVALID_FOLDER_CHARS, "-")
            .replace(MULTIPLE_WHITESPACE, " ")
            .trim(' ', '.')
            .trim()
        return sanitized.takeIf { it.any { ch -> ch != '-' && !ch.isWhitespace() } }
    }

    fun relativePath(
        mediaRootDirectory: String,
        settings: DownloadFolderSettings,
        cameraDisplayName: String?,
        captureDate: String,
    ): String {
        val normalized = settings.normalized()
        val segments = buildList {
            add(mediaRootDirectory)
            add(normalized.rootFolderName)
            if (normalized.includeCameraName) {
                sanitizedFolderSegment(cameraDisplayName)?.let(::add)
            }
            if (normalized.includeDateFolder) {
                captureDateFolder(captureDate)?.let(::add)
            }
        }
        return segments.joinToString("/")
    }

    fun previewRelativePath(
        settings: DownloadFolderSettings,
        cameraDisplayName: String?,
        sampleCaptureDate: String,
    ): String =
        if (usesCustomTree(settings)) {
            customFolderSummary(settings)
        } else {
            relativePath(
                mediaRootDirectory = "Pictures",
                settings = settings,
                cameraDisplayName = cameraDisplayName,
                captureDate = sampleCaptureDate.ifBlank {
                    LocalDate.now().format(DateTimeFormatter.BASIC_ISO_DATE)
                },
            )
        }

    fun customTreeLabel(uri: Uri): String {
        val docId = runCatching { DocumentsContract.getTreeDocumentId(uri) }.getOrNull().orEmpty()
        return docId.substringAfterLast('/').substringAfterLast(':').ifBlank { "已选文件夹" }
    }

    private fun captureDateFolder(captureDate: String): String? {
        if (captureDate.length < 8) return null
        return runCatching {
            LocalDate.parse(captureDate.take(8), CAPTURE_DATE_INPUT).format(CAPTURE_DATE_OUTPUT)
        }.getOrNull()
    }
}

private fun DownloadFolderSettings.normalized(): DownloadFolderSettings =
    copy(
        rootFolderName = DownloadFolderPathPolicy.normalizedRootFolderName(rootFolderName),
        customTreeUri = customTreeUri?.takeIf { it.isNotBlank() },
        customTreeLabel = customTreeLabel?.trim()?.takeIf { it.isNotBlank() },
    )
