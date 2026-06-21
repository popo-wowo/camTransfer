package com.camtransfer.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
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

    @Test
    fun findsBoundedMissingHandlesForBackgroundProbeInLargeGallery() {
        val handles = ((1..80) + (82..160) + (162..240) + (245..320)).toList()

        val candidates = CameraVendorHiddenObjectProbePolicy.backgroundHiddenHandleCandidates(handles)

        assertEquals(listOf(81, 161, 241, 242, 243, 244), candidates)
    }

    @Test
    fun skipsBackgroundProbeWhenMissingHandleCountIsTooHigh() {
        val handles = (1..300).filter { it % 2 == 0 }

        val candidates = CameraVendorHiddenObjectProbePolicy.backgroundHiddenHandleCandidates(handles)

        assertEquals(emptyList<Int>(), candidates)
    }

}
