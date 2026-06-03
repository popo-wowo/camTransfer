package com.camtransfer.protocol

import org.junit.Assert.assertFalse
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
    fun skipsExtraStandardEnumerationWhenThereIsNoSpecifiedGalleryBecauseStandardPathIsPrimary() {
        assertFalse(
            CameraVendorGalleryDiscoveryPolicy.shouldIncludeStandardEnumeration(
                specifiedHandleCount = 0,
            )
        )
    }
}
