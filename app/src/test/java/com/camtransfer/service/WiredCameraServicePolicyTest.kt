package com.camtransfer.service

import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WiredCameraServicePolicyTest {
    @Test
    fun supportedFormatsIncludeCommonPhotosRawAndVideo() {
        assertTrue(WiredCameraMtpPolicy.isSupportedFormat(PtpObjectFormat.JPEG, "DSCF0001.JPG"))
        assertTrue(WiredCameraMtpPolicy.isSupportedFormat(PtpObjectFormat.HEIF, "DSCF0002.HIF"))
        assertTrue(WiredCameraMtpPolicy.isSupportedFormat(PtpObjectFormat.CAMERA_VENDOR_RAF, "DSCF0003.RAF"))
        assertTrue(WiredCameraMtpPolicy.isSupportedFormat(PtpObjectFormat.MP4, "DSCF0004.MP4"))
        assertFalse(WiredCameraMtpPolicy.isSupportedFormat(PtpObjectFormat.ASSOCIATION, "DCIM"))
    }

    @Test
    fun mtpDateSecondsConvertToGalleryCaptureDateText() {
        assertEquals(
            "20260531T204102",
            WiredCameraMtpPolicy.captureDateText(dateCreatedSeconds = 1_780_231_262L),
        )
        assertEquals("", WiredCameraMtpPolicy.captureDateText(dateCreatedSeconds = 0L))
    }

    @Test
    fun syntheticHandleCombinesStorageAndObjectHandle() {
        assertEquals(0x00020005, WiredCameraMtpPolicy.syntheticHandle(storageId = 2, objectHandle = 5))
    }
}
