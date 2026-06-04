package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorThumbnailReadPolicyTest {
    @Test
    fun primesObjectContextBeforeStandardThumbnailRead() {
        assertTrue(CameraVendorThumbnailReadPolicy.shouldPrimeObjectContextBeforeStandardThumbnail())
    }

    @Test
    fun standardThumbnailReadTimeoutIsShorterThanSocketDefault() {
        assertEquals(3_000, CameraVendorThumbnailReadPolicy.STANDARD_THUMB_TIMEOUT_MS)
    }
}
