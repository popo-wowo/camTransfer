package com.camtransfer.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class CameraVendorBleWriteTypePolicyTest {

    @Test
    fun securePairingWritesUseResponseLikeIos() {
        assertTrue(
            CameraVendorBleWriteTypePolicy.shouldWriteWithResponse(
                CameraVendorBleProfile.IDENTIFIER_CHAR,
                hasGattWriteProperty = false,
            )
        )
        assertTrue(
            CameraVendorBleWriteTypePolicy.shouldWriteWithResponse(
                CameraVendorBleProfile.SECURE_STATUS_CHAR,
                hasGattWriteProperty = false,
            )
        )
    }

    @Test
    fun referenceAppActivationWritesUseResponseLikeIos() {
        assertTrue(
            CameraVendorBleWriteTypePolicy.shouldWriteWithResponse(
                CameraVendorBleProfile.LAUNCH_REQUEST_CHAR,
                hasGattWriteProperty = false,
            )
        )
    }

    @Test
    fun unknownCharacteristicsOnlyUseResponseWhenGattAdvertisesWrite() {
        val unknown = UUID.fromString("00000000-0000-0000-0000-000000000001")

        assertTrue(
            CameraVendorBleWriteTypePolicy.shouldWriteWithResponse(
                unknown,
                hasGattWriteProperty = true,
            )
        )
        assertFalse(
            CameraVendorBleWriteTypePolicy.shouldWriteWithResponse(
                unknown,
                hasGattWriteProperty = false,
            )
        )
    }
}
