package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorGalleryDiagnosticPolicyTest {
    @Test
    fun dateGroupSummaryIncludesTotalsAndNewestBuckets() {
        val groups = listOf(
            CameraVendorObjectCountByDate("20260622", 3),
            CameraVendorObjectCountByDate("20260621", 2),
            CameraVendorObjectCountByDate("20260620", 5),
        )

        val summary = CameraVendorGalleryDiagnosticPolicy.dateGroupSummary(groups)

        assertEquals("groups=3 total=10 summary=20260622:3, 20260621:2, 20260620:5", summary)
    }

    @Test
    fun handleSummaryIncludesRangeEdgesAndSmallGaps() {
        val handles = listOf(1109, 1101, 1100, 1098)

        val summary = CameraVendorGalleryDiagnosticPolicy.handleSummary(
            handles = handles,
            expectedCount = 4,
        )

        assertTrue(summary.contains("count=4 expected=4"))
        assertTrue(summary.contains("min=1098 max=1109"))
        assertTrue(summary.contains("first=1109,1101,1100,1098"))
        assertTrue(summary.contains("last=1109,1101,1100,1098"))
        assertTrue(summary.contains("smallGaps=1098-1100:1, 1101-1109:7"))
    }

    @Test
    fun handleSummaryFlagsCountMismatch() {
        val summary = CameraVendorGalleryDiagnosticPolicy.handleSummary(
            handles = listOf(3, 2, 1),
            expectedCount = 4,
        )

        assertTrue(summary.contains("countMismatch=true"))
    }
}
