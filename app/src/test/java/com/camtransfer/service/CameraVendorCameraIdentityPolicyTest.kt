package com.camtransfer.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorCameraIdentityPolicyTest {
    @Test
    fun cameraIdUsesOfficialSerialAndProductNameShape() {
        assertEquals(
            "221019F1932011003B_X-T5",
            CameraVendorCameraIdentityPolicy.cameraId(
                serialNumber = "221019F1932011003B",
                deviceName = "X-T5",
            ),
        )
    }

    @Test
    fun cameraIdFallsBackToSavedAddressWhenCameraMetadataIsMissing() {
        assertEquals(
            "AA:BB:CC:DD:EE:FF",
            CameraVendorCameraIdentityPolicy.cameraId(
                serialNumber = "",
                deviceName = "",
                bluetoothAddress = "AA:BB:CC:DD:EE:FF",
            ),
        )
    }

    @Test
    fun rememberedCameraMatchesOnlyTheSameStableIdentityWhenAvailable() {
        val remembered = CameraVendorPairedCameraRecord(
            cameraId = "221019F1932011003B_X-T5",
            deviceName = "X-T5",
            serialNumber = "221019F1932011003B",
            wifiConfigurations = emptyList(),
            bluetoothAddress = "AA:BB:CC:DD:EE:FF",
        )

        assertTrue(
            CameraVendorCameraIdentityPolicy.matches(
                remembered = remembered,
                candidateCameraId = "221019F1932011003B_X-T5",
                candidateSerialNumber = "221019F1932011003B",
                candidateDeviceName = "X-T5",
                candidateBluetoothAddress = "AA:BB:CC:DD:EE:FF",
            ),
        )
        assertFalse(
            CameraVendorCameraIdentityPolicy.matches(
                remembered = remembered,
                candidateCameraId = "999999999999999999_X-T5",
                candidateSerialNumber = "999999999999999999",
                candidateDeviceName = "X-T5",
                candidateBluetoothAddress = "AA:BB:CC:DD:EE:FF",
            ),
        )
    }

    @Test
    fun rememberedCameraCanMatchSystemBondFallbackByAddressBeforeStableCameraIdExists() {
        val remembered = CameraVendorPairedCameraRecord(
            cameraId = "AA:BB:CC:DD:EE:FF",
            deviceName = "X-T5",
            serialNumber = "",
            wifiConfigurations = emptyList(),
            bluetoothAddress = "AA:BB:CC:DD:EE:FF",
        )

        assertTrue(
            CameraVendorCameraIdentityPolicy.matches(
                remembered = remembered,
                candidateCameraId = "221019F1932011003B_X-T5",
                candidateSerialNumber = "221019F1932011003B",
                candidateDeviceName = "X-T5",
                candidateBluetoothAddress = "AA:BB:CC:DD:EE:FF",
            ),
        )
    }
}
