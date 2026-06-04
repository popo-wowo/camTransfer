package com.camtransfer.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorHiddenObjectProbePolicyTest {
    @Test
    fun probesWhenSpecifiedHandleRangeIsSmallEnoughEvenIfSomeHeifAlreadyExists() {
        assertTrue(CameraVendorHiddenObjectProbePolicy.shouldProbeHiddenHandles(listOf(10, 12, 15)))
    }

    @Test
    fun skipsLargeSpecifiedGalleryToKeepInitialAlbumFast() {
        assertFalse(CameraVendorHiddenObjectProbePolicy.shouldProbeHiddenHandles((1..2_000).toList()))
    }

    @Test
    fun skipsWhenRangeIsTooLargeToAvoidCameraPressure() {
        assertFalse(CameraVendorHiddenObjectProbePolicy.shouldProbeHiddenHandles(listOf(1, 500)))
    }
}
