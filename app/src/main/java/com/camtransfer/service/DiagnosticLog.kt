package com.camtransfer.service

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import com.camtransfer.BuildConfig
import com.camtransfer.model.CameraFile
import com.camtransfer.protocol.PtpObjectFormat
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object DiagnosticLog {
    private const val DirectoryName = "diagnostics"
    private const val FileName = "camtransfer-diagnostic-log.txt"
    private const val ExportFileName = "camtransfer-diagnostic-export.txt"
    private const val MaxBytes = 2 * 1024 * 1024
    private const val ExportWindowMillis = 60 * 60 * 1000L
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    @Synchronized
    fun append(context: Context, tag: String, message: String, throwable: Throwable? = null) {
        val file = logFile(context)
        file.parentFile?.mkdirs()
        trimIfNeeded(file)
        val text = buildString {
            append(timestampFormat.format(Date()))
            append(" [")
            append(tag)
            append("] ")
            append(DiagnosticLogRedactor.redacted(message))
            if (throwable != null) {
                append(" error=")
                append(DiagnosticLogRedactor.redacted(throwable.stackTraceToString()))
            }
            append('\n')
        }
        file.appendText(text)
    }

    fun appendCrash(context: Context, thread: Thread, throwable: Throwable) {
        append(
            context = context,
            tag = "Crash",
            message = DiagnosticCrashLogPolicy.entry(thread.name, throwable),
        )
    }

    fun appendFileSummary(context: Context, files: List<CameraFile>) {
        val formatCounts = files.groupingBy { it.info.formatLabel }.eachCount()
        append(
            context,
            "Gallery",
            "File list loaded total=${files.size} formats=$formatCounts",
        )
        files.take(300).forEach { file ->
            val info = file.info
            append(
                context,
                "GalleryFile",
                String.format(
                    Locale.US,
                    "handle=%d format=0x%04X label=%s size=%d",
                    info.handle,
                    info.format,
                    info.formatLabel,
                    info.compressedSize,
                ),
            )
        }
        if (files.size > 300) {
            append(context, "Gallery", "File summary truncated remaining=${files.size - 300}")
        }
    }

    fun appendMetadataSnapshot(context: Context, label: String, files: List<CameraFile>) {
        GalleryMetadataDiagnosticPolicy.snapshotLines(label, files).forEach { line ->
            append(context, "GalleryMetadata", line)
        }
    }

    fun shareIntent(context: Context): Intent {
        val file = exportFile(context)
        val uri = FileProvider.getUriForFile(context, "${BuildConfig.APPLICATION_ID}.fileprovider", file)
        return Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "CamTransfer 诊断日志")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun exportFile(context: Context): File {
        val file = logFile(context)
        file.parentFile?.mkdirs()
        if (!file.exists()) file.writeText("")
        val exportFile = File(file.parentFile, ExportFileName)
        val generatedAt = Date()
        val header = DiagnosticLogHeader.build()
        val body = DiagnosticLogExportPolicy.recentBody(
            raw = DiagnosticLogRedactor.redacted(file.readText()),
            generatedAt = generatedAt,
            windowMillis = ExportWindowMillis,
        )
        exportFile.writeText(header + body)
        return exportFile
    }

    private fun logFile(context: Context): File =
        File(File(context.cacheDir, DirectoryName), FileName)

    private fun trimIfNeeded(file: File) {
        if (!file.exists() || file.length() <= MaxBytes) return
        val text = file.readText()
        file.writeText(text.takeLast(MaxBytes / 2))
    }
}

object GalleryMetadataDiagnosticPolicy {
    private const val LargeFileThresholdBytes = 8 * 1024 * 1024
    private const val MaxLargeFileLines = 24

    fun snapshotLines(label: String, files: List<CameraFile>): List<String> {
        val formatCounts = files.groupingBy { it.info.formatLabel }.eachCount()
        val unresolvedCount = files.count { it.info.format == PtpObjectFormat.UNDEFINED }
        val largeFiles = files
            .filter { it.info.compressedSize >= LargeFileThresholdBytes }
            .sortedWith(compareByDescending<CameraFile> { it.info.compressedSize }.thenByDescending { it.info.handle })
        return buildList {
            add(
                "Metadata snapshot $label total=${files.size} formats=$formatCounts " +
                    "unresolved=$unresolvedCount largeFiles=${largeFiles.size}"
            )
            largeFiles.take(MaxLargeFileLines).forEach { file ->
                val info = file.info
                add(
                    String.format(
                        Locale.US,
                        "Metadata large %s handle=%d format=0x%04X label=%s size=%d",
                        label,
                        info.handle,
                        info.format,
                        info.formatLabel,
                        info.compressedSize,
                    )
                )
            }
            if (largeFiles.size > MaxLargeFileLines) {
                add("Metadata large $label truncated remaining=${largeFiles.size - MaxLargeFileLines}")
            }
        }
    }
}

object DiagnosticLogExportPolicy {
    val timestampFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    private val timestampPrefix = Regex("""^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} """)

    fun recentBody(raw: String, generatedAt: Date, windowMillis: Long): String {
        val cutoff = generatedAt.time - windowMillis
        val output = StringBuilder()
        var includeCurrentEntry = false

        raw.lineSequence().forEach { line ->
            val timestamp = timestampAtStart(line)
            if (timestamp != null) {
                includeCurrentEntry = timestamp.time >= cutoff && timestamp.time <= generatedAt.time
            }
            if (includeCurrentEntry) {
                output.append(line).append('\n')
            }
        }

        return if (output.isEmpty()) {
            "最近 1 小时没有诊断日志。\n"
        } else {
            output.toString()
        }
    }

    private fun timestampAtStart(line: String): Date? {
        if (!timestampPrefix.containsMatchIn(line)) return null
        return runCatching {
            synchronized(timestampFormat) {
                timestampFormat.parse(line.take(23))
            }
        }.getOrNull()
    }
}

object DiagnosticLogHeader {
    fun build(): String {
        val deviceInfo = DiagnosticDeviceInfoPolicy.summary(
            manufacturer = Build.MANUFACTURER,
            brand = Build.BRAND,
            model = Build.MODEL,
            product = Build.PRODUCT,
            device = Build.DEVICE,
            supportedAbis = Build.SUPPORTED_ABIS,
        )
        return "CamTransfer Android Diagnostic Log\n" +
            "App Version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})\n" +
            "Build Type: ${BuildConfig.BUILD_TYPE}\n" +
            "Package: ${BuildConfig.APPLICATION_ID}\n" +
            deviceInfo.joinToString(separator = "\n", postfix = "\n") +
            "Android: ${Build.VERSION.RELEASE} API ${Build.VERSION.SDK_INT}\n" +
            "Generated At: ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())}\n\n"
    }
}

object DiagnosticDeviceInfoPolicy {
    fun summary(
        manufacturer: String?,
        brand: String?,
        model: String?,
        product: String?,
        device: String?,
        supportedAbis: Array<String>?,
    ): List<String> {
        val phone = listOf(manufacturer, brand, model)
            .map { it.cleanUnknown() }
            .distinct()
            .joinToString(" ")
            .ifBlank { "unknown" }
        return listOf(
            "Phone: $phone",
            "Product: ${product.cleanUnknown()}",
            "Device Code: ${device.cleanUnknown()}",
            "ABIs: ${supportedAbis.orEmpty().filter { it.isNotBlank() }.joinToString(", ").ifBlank { "unknown" }}",
        )
    }

    private fun String?.cleanUnknown(): String =
        this?.trim()?.takeIf { it.isNotBlank() } ?: "unknown"
}

object DiagnosticCrashLogPolicy {
    fun entry(threadName: String, throwable: Throwable): String =
        DiagnosticLogRedactor.redacted(
            "Uncaught crash thread=$threadName\n${throwable.stackTraceToString()}"
        )
}

object DiagnosticLogRedactor {
    private val patterns = listOf(
        Regex("""(?i)(密码\s*[:：]\s*)([^\n\r]+)"""),
        Regex("""(?i)(passphrase\s*[=:：]\s*)([^\n\r]+)"""),
        Regex("""(?i)(password\s*[=:：]\s*)([^\n\r]+)"""),
        Regex("""(?i)\b(filename|name|ssid|device|camera|serial|address|bluetoothAddress|path)\s*([=:：])(\s*)([^\s,\n\r]+)"""),
        Regex("""(?i)(正在连接\s*WiFi\s*[:：]\s*)([^\n\r]+)"""),
        Regex("""(?i)(正在等待手机加入相机\s*Wi-?Fi\s*[:：]\s*)([^\s,\n\r]+)"""),
        Regex("""(?i)(Wi-?Fi\s*名称\s*[:：]\s*)([^\n\r]+)"""),
        Regex("""(?i)(已尝试\s*[:：]\s*)([^\n\r]+)"""),
        Regex("""(?i)(SSID\s*[:：]\s*)([^\n\r]+)"""),
        Regex("""(?i)(Device\s*[:：]\s*)([^\n\r]+)"""),
        Regex("""\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b"""),
    )

    fun redacted(text: String): String =
        patterns.fold(text) { current, pattern ->
            pattern.replace(current) { match ->
                when {
                    match.groupValues.size >= 3 &&
                        match.groupValues[1].contains(Regex("""(?i)pass|password|密码""")) ->
                        match.groupValues[1] + "********"
                    match.groupValues.size >= 5 && match.groupValues[2].isNotEmpty() ->
                        match.groupValues[1] + match.groupValues[2] + match.groupValues[3] + "[redacted]"
                    match.groupValues.size >= 3 && match.groupValues[1].isNotEmpty() ->
                        match.groupValues[1] + "[redacted]"
                    else -> "[redacted]"
                }
            }
        }
}
