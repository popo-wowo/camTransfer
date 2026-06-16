package com.camtransfer.ui

import com.camtransfer.service.CameraVendorPairedCameraRecord
import com.camtransfer.viewmodel.ConnectionState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionPairedCameraSelectorPolicyTest {
    @Test
    fun selectorOnlyShowsForMultiplePairedCamerasInPairedState() {
        val first = record("111_X-T5")
        val second = record("222_X100VI")

        assertFalse(
            ConnectionUiLayoutPolicy.shouldShowPairedCameraSelector(
                state = ConnectionState.PAIRED,
                pairedCameras = listOf(first),
            )
        )
        assertFalse(
            ConnectionUiLayoutPolicy.shouldShowPairedCameraSelector(
                state = ConnectionState.CONNECTING_BLE,
                pairedCameras = listOf(first, second),
            )
        )
        assertTrue(
            ConnectionUiLayoutPolicy.shouldShowPairedCameraSelector(
                state = ConnectionState.PAIRED,
                pairedCameras = listOf(first, second),
            )
        )
    }

    private fun record(cameraId: String): CameraVendorPairedCameraRecord =
        CameraVendorPairedCameraRecord(
            cameraId = cameraId,
            deviceName = cameraId.substringAfter("_"),
            serialNumber = cameraId.substringBefore("_"),
            wifiConfigurations = emptyList(),
        )
}
