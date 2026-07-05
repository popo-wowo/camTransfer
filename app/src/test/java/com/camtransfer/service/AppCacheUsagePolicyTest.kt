package com.camtransfer.service

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppCacheUsagePolicyTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun cacheUsageCountsOnlyClearableCacheDirectories() {
        val cacheDir = temporaryFolder.newFolder("cache")
        writeBytes(File(cacheDir, "hd-preview-cache/a.bin"), 4)
        writeBytes(File(cacheDir, "diagnostics/camtransfer-diagnostic-log.txt"), 6)
        writeBytes(File(cacheDir, "thumbnail-disk-cache/thumb.bin"), 8)
        writeBytes(File(cacheDir, "not-clearable/keep.bin"), 100)

        val usage = AppCacheUsagePolicy.usage(cacheDir)

        assertEquals(14L, usage.bytes)
        assertFalse(usage.countedPaths.any { it.endsWith("hd-preview-cache") })
        assertTrue(usage.countedPaths.any { it.endsWith("diagnostics") })
        assertTrue(usage.countedPaths.any { it.endsWith("thumbnail-disk-cache") })
        assertFalse(usage.countedPaths.any { it.endsWith("not-clearable") })
    }

    @Test
    fun cacheLimitOptionsAreFixedUserVisibleCaps() {
        assertEquals(
            listOf(200L * 1024L * 1024L, 500L * 1024L * 1024L, 1024L * 1024L * 1024L),
            AppCacheLimitOption.entries.map { it.bytes },
        )
        assertEquals(listOf("200 MB", "500 MB", "1 GB"), AppCacheLimitOption.entries.map { it.label })
    }

    @Test
    fun trimToLimitDeletesOldClearableFilesOnly() {
        val cacheDir = temporaryFolder.newFolder("cache")
        val oldThumb = File(cacheDir, "thumbnail-disk-cache/old.bin")
        val newThumb = File(cacheDir, "thumbnail-disk-cache/new.bin")
        val diagnostics = File(cacheDir, "diagnostics/log.txt")
        val hdPreview = File(cacheDir, "hd-preview-cache/preview.bin")
        val pairing = File(cacheDir, "pairing/keep.bin")
        writeBytes(oldThumb, 8)
        writeBytes(newThumb, 8)
        writeBytes(diagnostics, 4)
        writeBytes(hdPreview, 100)
        writeBytes(pairing, 100)
        oldThumb.setLastModified(1)
        diagnostics.setLastModified(2)
        newThumb.setLastModified(3)

        val result = AppCacheUsagePolicy.trimToLimit(cacheDir, maxBytes = 10)

        assertEquals(2, result.deletedFiles)
        assertEquals(8L, AppCacheUsagePolicy.usage(cacheDir).bytes)
        assertFalse(oldThumb.exists())
        assertFalse(diagnostics.exists())
        assertTrue(newThumb.exists())
        assertTrue(hdPreview.exists())
        assertTrue(pairing.exists())
    }

    @Test
    fun cacheUsageFormatsReadableValues() {
        assertEquals("缓存 0 KB", AppCacheUsagePolicy.format(0))
        assertEquals("缓存 512 KB", AppCacheUsagePolicy.format(512 * 1024))
        assertEquals("缓存 1.5 MB", AppCacheUsagePolicy.format(1536 * 1024))
        assertEquals("缓存 1.0 GB", AppCacheUsagePolicy.format(1024L * 1024L * 1024L))
    }

    private fun writeBytes(file: File, size: Int) {
        file.parentFile?.mkdirs()
        file.writeBytes(ByteArray(size) { 1 })
    }
}
