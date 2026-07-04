package com.camtransfer.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorOfficialGalleryStartupPolicyTest {

    @Test
    fun officialConnectionStageDoesNotPreloadGalleryObjects() {
        val steps = CameraVendorOfficialGalleryStartupPolicy.connectionStageOperations()

        assertTrue(steps.contains(CameraVendorOfficialGalleryStartupOperation.SetFunctionMode))
        assertTrue(steps.contains(CameraVendorOfficialGalleryStartupOperation.SetFunctionVersion))
        assertFalse(steps.contains(CameraVendorOfficialGalleryStartupOperation.GetLatestObjectInfo))
        assertFalse(steps.contains(CameraVendorOfficialGalleryStartupOperation.GetExtensionThumb))
        assertFalse(steps.contains(CameraVendorOfficialGalleryStartupOperation.GetSpecifiedObjectHandles))
    }

    @Test
    fun functionVersionUsesReturnedLittleEndianValue() {
        assertEquals(
            3,
            CameraVendorOfficialGalleryStartupPolicy.functionVersion(byteArrayOf(0x03, 0x00, 0x00, 0x00)),
        )
    }

    @Test
    fun initialGallerySearchRequestsEveryStillAndMovieFormat() {
        assertEquals(
            CameraVendorSearchMode.ALL_FORMATS,
            CameraVendorOfficialGalleryStartupPolicy.initialObjectFormatMask(),
        )
    }

    @Test
    fun expandedGalleryStartupPassOnlyChecksStillExpansionFormats() {
        assertEquals(
            listOf(CameraVendorSearchMode.FORMAT_HEIF, CameraVendorSearchMode.FORMAT_RAW),
            CameraVendorOfficialGalleryStartupPolicy.expandedStillFormatMasks(),
        )
    }

    @Test
    fun blockingGalleryStartupDoesNotReadCurrentObjectHandleSnapshot() {
        assertFalse(CameraVendorOfficialGalleryStartupPolicy.shouldReadCurrentObjectHandleSnapshotDuringBlockingStartup())
    }
}
