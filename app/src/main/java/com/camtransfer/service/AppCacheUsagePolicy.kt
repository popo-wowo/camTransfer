package com.camtransfer.service

import android.content.Context
import java.io.File
import java.util.Locale

object AppCacheUsagePolicy {
    private val ClearableCacheDirectoryNames = listOf(
        "thumbnail-disk-cache",
        "diagnostics",
    )

    fun usage(cacheDir: File): AppCacheUsage {
        val countedDirs = ClearableCacheDirectoryNames
            .map { File(cacheDir, it) }
            .filter { it.exists() }
        return AppCacheUsage(
            bytes = countedDirs.sumOf(::directorySize),
            countedPaths = countedDirs.map { it.path },
        )
    }

    fun trimToLimit(cacheDir: File, maxBytes: Long): AppCacheTrimResult {
        var usageBytes = usage(cacheDir).bytes
        if (usageBytes <= maxBytes) {
            return AppCacheTrimResult(deletedFiles = 0, deletedBytes = 0)
        }
        var deletedFiles = 0
        var deletedBytes = 0L
        clearableFiles(cacheDir)
            .sortedBy { it.lastModified() }
            .forEach { file ->
                if (usageBytes <= maxBytes) return@forEach
                val size = file.length()
                if (file.delete()) {
                    usageBytes -= size
                    deletedBytes += size
                    deletedFiles += 1
                }
            }
        return AppCacheTrimResult(
            deletedFiles = deletedFiles,
            deletedBytes = deletedBytes,
        )
    }

    fun clearSessionPreviewCache(cacheDir: File): Boolean =
        File(cacheDir, SESSION_PREVIEW_CACHE_DIRECTORY_NAME).deleteRecursively()

    fun format(bytes: Long): String {
        val kb = 1024L
        val mb = kb * 1024L
        val gb = mb * 1024L
        return when {
            bytes >= gb -> "缓存 ${oneDecimal(bytes.toDouble() / gb)} GB"
            bytes >= mb -> "缓存 ${oneDecimal(bytes.toDouble() / mb)} MB"
            else -> "缓存 ${bytes / kb} KB"
        }
    }

    private fun clearableFiles(cacheDir: File): List<File> =
        ClearableCacheDirectoryNames
            .map { File(cacheDir, it) }
            .flatMap(::filesIn)
            .filter { it.isFile }

    private fun filesIn(file: File): List<File> {
        if (!file.exists()) return emptyList()
        if (file.isFile) return listOf(file)
        return file.listFiles()?.flatMap(::filesIn).orEmpty()
    }

    private fun directorySize(file: File): Long {
        if (!file.exists()) return 0L
        if (file.isFile) return file.length()
        return file.listFiles()?.sumOf(::directorySize) ?: 0L
    }

    private fun oneDecimal(value: Double): String =
        String.format(Locale.US, "%.1f", value)

    const val SESSION_PREVIEW_CACHE_DIRECTORY_NAME = "hd-preview-cache"
}

data class AppCacheUsage(
    val bytes: Long,
    val countedPaths: List<String>,
)

data class AppCacheTrimResult(
    val deletedFiles: Int,
    val deletedBytes: Long,
)

enum class AppCacheLimitOption(
    val bytes: Long,
    val label: String,
) {
    MB_200(200L * 1024L * 1024L, "200 MB"),
    MB_500(500L * 1024L * 1024L, "500 MB"),
    GB_1(1024L * 1024L * 1024L, "1 GB"),
}

class AppCacheSettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun loadLimit(): AppCacheLimitOption =
        prefs.getString(KEY_LIMIT, AppCacheLimitOption.MB_500.name)
            ?.let { value -> AppCacheLimitOption.entries.firstOrNull { it.name == value } }
            ?: AppCacheLimitOption.MB_500

    fun saveLimit(option: AppCacheLimitOption) {
        prefs.edit()
            .putString(KEY_LIMIT, option.name)
            .apply()
    }

    private companion object {
        const val PREFS_NAME = "camtransfer.cache_settings"
        const val KEY_LIMIT = "persistent_cache_limit"
    }
}
