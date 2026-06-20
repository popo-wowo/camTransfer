package com.camtransfer.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorGalleryDiscoveryPolicyTest {
    @Test
    fun includesStandardEnumerationWheneverSpecifiedGalleryIsPartialSource() {
        assertTrue(
            CameraVendorGalleryDiscoveryPolicy.shouldIncludeStandardEnumeration(
                specifiedHandleCount = 1,
            )
        )
        assertTrue(
            CameraVendorGalleryDiscoveryPolicy.shouldIncludeStandardEnumeration(
                specifiedHandleCount = 8,
            )
        )
    }

    @Test
    fun skipsExtraStandardEnumerationForLargeSpecifiedGallery() {
        assertFalse(
            CameraVendorGalleryDiscoveryPolicy.shouldIncludeStandardEnumeration(
                specifiedHandleCount = 2_000,
            )
        )
    }

    @Test
    fun skipsExtraStandardEnumerationWhenThereIsNoSpecifiedGalleryBecauseStandardPathIsPrimary() {
        assertFalse(
            CameraVendorGalleryDiscoveryPolicy.shouldIncludeStandardEnumeration(
                specifiedHandleCount = 0,
            )
        )
    }

    @Test
    fun limitsInitialSpecifiedHandlesForLargeGalleryToNewestBatch() {
        val handles = (1..2_000).toList()

        val initial = CameraVendorGalleryDiscoveryPolicy.initialSpecifiedHandles(handles)

        assertEquals(CameraVendorGalleryDiscoveryPolicy.INITIAL_LARGE_GALLERY_HANDLE_LIMIT, initial.size)
        assertEquals(2_000, initial.first())
        assertEquals(1_801, initial.last())
    }

    @Test
    fun keepsAllSpecifiedHandlesForSmallGallery() {
        val handles = (1..60).toList()

        val initial = CameraVendorGalleryDiscoveryPolicy.initialSpecifiedHandles(handles)

        assertEquals(handles.sortedDescending(), initial)
    }

    @Test
    fun placeholderHandlesUseNewestBatchWithoutWaitingForObjectInfo() {
        val handles = (1..600).toList()

        val initial = CameraVendorGalleryDiscoveryPolicy.initialPlaceholderHandles(handles)

        assertEquals(600, initial.size)
        assertEquals(600, initial.first())
        assertEquals(1, initial.last())
    }

    @Test
    fun mapsDateCountsOntoSpecifiedHandlesInNewestOrder() {
        val handles = listOf(10, 11, 12, 13, 14)
        val dates = listOf(
            CameraVendorObjectCountByDate(dateValue = "20260620", numberOfImages = 2),
            CameraVendorObjectCountByDate(dateValue = "20260619", numberOfImages = 3),
        )

        val result = CameraVendorGalleryDiscoveryPolicy.captureDatesByHandle(handles, dates)

        assertEquals("20260620", result[14])
        assertEquals("20260620", result[13])
        assertEquals("20260619", result[12])
        assertEquals("20260619", result[11])
        assertEquals("20260619", result[10])
    }

    @Test
    fun stopsDateMappingWhenDateCountsExceedAvailableHandles() {
        val result = CameraVendorGalleryDiscoveryPolicy.captureDatesByHandle(
            specifiedHandles = listOf(1, 2),
            countsByDate = listOf(CameraVendorObjectCountByDate("20260620", 3)),
        )

        assertEquals(mapOf(2 to "20260620", 1 to "20260620"), result)
    }
}
