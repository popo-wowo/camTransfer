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

        assertEquals(CameraVendorGalleryDiscoveryPolicy.INITIAL_LARGE_GALLERY_HANDLE_LIMIT, initial.size)
        assertEquals(600, initial.first())
        assertEquals(401, initial.last())
    }
}
