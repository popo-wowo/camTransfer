package com.camtransfer.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPartialObjectReadPolicyTest {
    @Test
    fun doesNotStopAtJpegMarkerWhenExpectedSizeIsKnown() {
        assertFalse(
            CameraVendorPartialObjectReadPolicy.shouldStopAfterChunk(
                expectedSize = 56_347_136,
                previousLastByte = null,
                chunk = byteArrayOf(0x01, 0x02, 0xFF.toByte(), 0xD9.toByte()),
                offset = 4,
                maxBytes = 56_347_136,
            )
        )
    }

    @Test
    fun stopsAtJpegMarkerOnlyWhenExpectedSizeIsUnknown() {
        assertTrue(
            CameraVendorPartialObjectReadPolicy.shouldStopAfterChunk(
                expectedSize = null,
                previousLastByte = null,
                chunk = byteArrayOf(0x01, 0x02, 0xFF.toByte(), 0xD9.toByte()),
                offset = 4,
                maxBytes = CameraVendorReferenceApp.PARTIAL_MAX_BYTES_WITHOUT_KNOWN_SIZE,
            )
        )
    }

    @Test
    fun alwaysStopsWhenExpectedSizeIsFullyRead() {
        assertTrue(
            CameraVendorPartialObjectReadPolicy.shouldStopAfterChunk(
                expectedSize = 4,
                previousLastByte = null,
                chunk = byteArrayOf(0x01, 0x02, 0x03, 0x04),
                offset = 4,
                maxBytes = 4,
            )
        )
    }
}
