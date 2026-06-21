package com.camtransfer.service

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class DiagnosticLogTest {
    @Test
    fun redactsWifiPasswordsAndPassphrases() {
        val raw = """
            SSID: CAM-1234
            密码: 12345678
            passphrase=87654321
            password: camera-secret
        """.trimIndent()

        val redacted = DiagnosticLogRedactor.redacted(raw)

        assertTrue(redacted.contains("SSID: [redacted]"))
        assertTrue(redacted.contains("密码: ********"))
        assertTrue(redacted.contains("passphrase=********"))
        assertTrue(redacted.contains("password: ********"))
        assertFalse(redacted.contains("12345678"))
        assertFalse(redacted.contains("CAM-1234"))
        assertFalse(redacted.contains("87654321"))
        assertFalse(redacted.contains("camera-secret"))
    }

    @Test
    fun redactsDeviceFileAndNetworkIdentifiers() {
        val raw = """
            filename=DSCF0001.JPG name=X-T5 camera=FUJIFILM-X-T5 serial=ABC123
            ssid=FUJIFILM-X-T5-1234 address=AA:BB:CC:DD:EE:FF bluetoothAddress=11:22:33:44:55:66
            正在连接 WiFi: FUJIFILM-X-T5-1234 (1/2)
            已尝试: FUJIFILM-X-T5-1234, FUJIFILM-X-T5-5678
            Device: Xiaomi 23127PN0CC
        """.trimIndent()

        val redacted = DiagnosticLogRedactor.redacted(raw)

        assertFalse(redacted.contains("DSCF0001.JPG"))
        assertFalse(redacted.contains("FUJIFILM-X-T5-1234"))
        assertFalse(redacted.contains("FUJIFILM-X-T5-5678"))
        assertFalse(redacted.contains("AA:BB:CC:DD:EE:FF"))
        assertFalse(redacted.contains("11:22:33:44:55:66"))
        assertFalse(redacted.contains("ABC123"))
        assertFalse(redacted.contains("23127PN0CC"))
        assertTrue(redacted.contains("filename=[redacted]"))
        assertTrue(redacted.contains("Device: [redacted]"))
    }

    @Test
    fun headerContainsAndroidDiagnosticTitle() {
        val header = DiagnosticLogHeader.build()

        assertTrue(header.contains("CamTransfer Android Diagnostic Log"))
        assertTrue(header.contains("App Version:"))
        assertTrue(header.contains("Build Type:"))
        assertTrue(header.contains("Package:"))
        assertTrue(header.contains("Phone:"))
        assertTrue(header.contains("Product:"))
        assertTrue(header.contains("Device Code:"))
        assertTrue(header.contains("ABIs:"))
        assertTrue(header.contains("Android:"))
        assertFalse(header.contains("Device: [redacted]"))
    }

    @Test
    fun deviceInfoSummaryIncludesUsefulNonUniqueFields() {
        val summary = DiagnosticDeviceInfoPolicy.summary(
            manufacturer = "Xiaomi",
            brand = "Redmi",
            model = "23127PN0CC",
            product = "aurora",
            device = "aurora",
            supportedAbis = arrayOf("arm64-v8a", "armeabi-v7a"),
        )

        assertEquals(
            listOf(
                "Phone: Xiaomi Redmi 23127PN0CC",
                "Product: aurora",
                "Device Code: aurora",
                "ABIs: arm64-v8a, armeabi-v7a",
            ),
            summary,
        )
    }

    @Test
    fun crashEntryIncludesThreadAndRedactedStackTrace() {
        val throwable = IllegalStateException("failed filename=DSCF0001.JPG ssid=CAMERA-1234")

        val entry = DiagnosticCrashLogPolicy.entry(
            threadName = "main",
            throwable = throwable,
        )

        assertTrue(entry.contains("Uncaught crash thread=main"))
        assertTrue(entry.contains("IllegalStateException"))
        assertTrue(entry.contains("filename=[redacted]"))
        assertTrue(entry.contains("ssid=[redacted]"))
        assertFalse(entry.contains("DSCF0001.JPG"))
        assertFalse(entry.contains("CAMERA-1234"))
    }

    @Test
    fun exportBodyKeepsOnlyEntriesWithinRecentWindowAndTheirStackLines() {
        val raw = """
            2026-05-31 09:59:59.999 [Old] too old
            old stack line
            2026-05-31 10:00:00.000 [Boundary] keep boundary
            boundary stack line
            2026-05-31 10:30:00.000 [Recent] keep recent
            recent stack line
        """.trimIndent()
        val generatedAt = Date(DiagnosticLogExportPolicy.timestampFormat.parse("2026-05-31 11:00:00.000")!!.time)

        val body = DiagnosticLogExportPolicy.recentBody(
            raw = raw,
            generatedAt = generatedAt,
            windowMillis = 60 * 60 * 1000,
        )

        assertFalse(body.contains("too old"))
        assertFalse(body.contains("old stack line"))
        assertTrue(body.contains("[Boundary] keep boundary"))
        assertTrue(body.contains("boundary stack line"))
        assertTrue(body.contains("[Recent] keep recent"))
        assertTrue(body.contains("recent stack line"))
    }

    @Test
    fun exportBodyAddsEmptyMessageWhenNoRecentEntriesExist() {
        val raw = "2026-05-31 09:00:00.000 [Old] too old"
        val generatedAt = Date(DiagnosticLogExportPolicy.timestampFormat.parse("2026-05-31 11:00:00.000")!!.time)

        val body = DiagnosticLogExportPolicy.recentBody(
            raw = raw,
            generatedAt = generatedAt,
            windowMillis = 60 * 60 * 1000,
        )

        assertEquals("最近 1 小时没有诊断日志。\n", body)
    }

    @Test
    fun galleryMetadataSnapshotHighlightsFormatCountsAndLargeFiles() {
        val files = listOf(
            cameraFile(handle = 1, format = PtpObjectFormat.JPEG, size = 167_936),
            cameraFile(handle = 2, format = PtpObjectFormat.HEIF, size = 9_000_000, filename = "DSCF0002.HIF"),
            cameraFile(handle = 3, format = PtpObjectFormat.CAMERA_VENDOR_RAF_ALT, size = 52_000_000, filename = "DSCF0003.RAF"),
            cameraFile(handle = 4, format = PtpObjectFormat.UNDEFINED, size = 0, filename = "0x00000004"),
        )

        val lines = GalleryMetadataDiagnosticPolicy.snapshotLines(
            label = "final",
            files = files,
        )

        assertEquals(
            "Metadata snapshot final total=4 formats={JPG=1, HEIF=1, RAW=1, 0x3000=1} unresolved=1 largeFiles=2",
            lines.first(),
        )
        assertTrue(lines.any { it.contains("Metadata large final handle=3 format=0xB103 label=RAW size=52000000") })
        assertTrue(lines.any { it.contains("Metadata large final handle=2 format=0x3812 label=HEIF size=9000000") })
    }

    private fun cameraFile(
        handle: Int,
        format: Int,
        size: Int,
        filename: String = "DSCF0001.JPG",
    ): CameraFile = CameraFile(
        ObjectInfo(
            handle = handle,
            storageId = 0,
            format = format,
            compressedSize = size,
            thumbFormat = 0,
            thumbCompressedSize = 0,
            thumbPixWidth = 0,
            thumbPixHeight = 0,
            imagePixWidth = 0,
            imagePixHeight = 0,
            parentObject = 0,
            filename = filename,
            captureDate = "20260620T120000",
        )
    )
}
