package com.camtransfer.protocol

import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferDownloadMode
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorDownloadModePolicyTest {
    @Test
    fun originalJpegDownloadUsesOfficialForceOriginalPath() {
        val prepares = CameraVendorDownloadModePolicy.prepareProperties(
            mode = TransferDownloadMode.ORIGINAL,
            objectInfo = objectInfo(format = PtpObjectFormat.JPEG, filename = "DSCF0001.JPG"),
        )
        val prepare = prepares.single()
        val reset = CameraVendorDownloadModePolicy.resetProperty(prepare)

        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, prepare.code)
        assertEquals(2, prepare.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, prepare.width)
        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, reset?.code)
        assertEquals(0, reset?.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, reset?.width)
    }

    @Test
    fun originalRawDownloadUsesOfficialForceOriginalPath() {
        val prepare = CameraVendorDownloadModePolicy.prepareProperty(
            mode = TransferDownloadMode.ORIGINAL,
            objectInfo = objectInfo(format = PtpObjectFormat.CAMERA_VENDOR_RAF_ALT, filename = "DSCF0001.RAF"),
        )
        val reset = CameraVendorDownloadModePolicy.resetProperty(prepare)

        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, prepare.code)
        assertEquals(2, prepare.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, prepare.width)
        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, reset?.code)
        assertEquals(0, reset?.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, reset?.width)
    }

    @Test
    fun compressedJpegDownloadSetsResizeRateBeforeForceCompressed() {
        val prepares = CameraVendorDownloadModePolicy.prepareProperties(
            mode = TransferDownloadMode.COMPRESSED,
            objectInfo = objectInfo(format = PtpObjectFormat.JPEG, filename = "DSCF0001.JPG"),
        )
        val rate = prepares[0]
        val force = prepares[1]
        val rateReset = CameraVendorDownloadModePolicy.resetProperty(rate)
        val forceReset = CameraVendorDownloadModePolicy.resetProperty(force)

        assertEquals(CameraVendorDevicePropCode.OBJECT_COMPRESSION_SETTING, rate.code)
        assertEquals(1, rate.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, rate.width)
        assertEquals(null, rateReset)
        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, force.code)
        assertEquals(1, force.value)
        assertEquals(CameraVendorDevicePropertyWidth.UINT16, force.width)
        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, forceReset?.code)
        assertEquals(0, forceReset?.value)
    }

    @Test
    fun compressedHeifDownloadUsesOfficialForceCompressedPath() {
        val prepares = CameraVendorDownloadModePolicy.prepareProperties(
            mode = TransferDownloadMode.COMPRESSED,
            objectInfo = objectInfo(format = PtpObjectFormat.HEIF, filename = "DSCF0001.HIF"),
        )

        assertEquals(CameraVendorDevicePropCode.OBJECT_COMPRESSION_SETTING, prepares[0].code)
        assertEquals(1, prepares[0].value)
        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, prepares[1].code)
        assertEquals(1, prepares[1].value)
    }

    @Test
    fun compressedRawDownloadUsesSameOfficialForceCompressedPath() {
        val prepares = CameraVendorDownloadModePolicy.prepareProperties(
            mode = TransferDownloadMode.COMPRESSED,
            objectInfo = objectInfo(format = PtpObjectFormat.CAMERA_VENDOR_RAF_ALT, filename = "DSCF0001.RAF"),
        )

        assertEquals(CameraVendorDevicePropCode.OBJECT_COMPRESSION_SETTING, prepares[0].code)
        assertEquals(1, prepares[0].value)
        assertEquals(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, prepares[1].code)
        assertEquals(1, prepares[1].value)
    }

    private fun objectInfo(format: Int, filename: String): ObjectInfo =
        ObjectInfo(
            handle = 1,
            storageId = 1,
            format = format,
            compressedSize = 1024,
            thumbFormat = PtpObjectFormat.JPEG,
            thumbCompressedSize = 128,
            thumbPixWidth = 160,
            thumbPixHeight = 120,
            imagePixWidth = 4000,
            imagePixHeight = 3000,
            parentObject = 0,
            filename = filename,
            captureDate = "20260624T230000",
        )
}
