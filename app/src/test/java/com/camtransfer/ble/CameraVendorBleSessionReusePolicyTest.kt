package com.camtransfer.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorBleSessionReusePolicyTest {
    @Test
    fun reusableSessionRequiresLiveGattTransferCharacteristicsIdentityMatchAndFreshAge() {
        assertTrue(
            CameraVendorBleSessionReusePolicy.canReuseForTransferActivation(
                hasLiveGatt = true,
                hasRequiredTransferCharacteristics = true,
                rememberedCameraMatches = true,
                hasCompletedCameraAck = true,
                ageMs = 30_000,
            ),
        )
    }

    @Test
    fun disconnectedSessionCannotBeReusedEvenWhenCachedMetadataExists() {
        assertFalse(
            CameraVendorBleSessionReusePolicy.canReuseForTransferActivation(
                hasLiveGatt = false,
                hasRequiredTransferCharacteristics = true,
                rememberedCameraMatches = true,
                hasCompletedCameraAck = true,
                ageMs = 30_000,
            ),
        )
    }

    @Test
    fun missingTransferCharacteristicsCannotBeReused() {
        assertFalse(
            CameraVendorBleSessionReusePolicy.canReuseForTransferActivation(
                hasLiveGatt = true,
                hasRequiredTransferCharacteristics = false,
                rememberedCameraMatches = true,
                hasCompletedCameraAck = true,
                ageMs = 30_000,
            ),
        )
    }

    @Test
    fun identityMismatchCannotBeReused() {
        assertFalse(
            CameraVendorBleSessionReusePolicy.canReuseForTransferActivation(
                hasLiveGatt = true,
                hasRequiredTransferCharacteristics = true,
                rememberedCameraMatches = false,
                hasCompletedCameraAck = true,
                ageMs = 30_000,
            ),
        )
    }

    @Test
    fun pendingCameraAckCannotBeReusedForTransferActivation() {
        assertFalse(
            CameraVendorBleSessionReusePolicy.canReuseForTransferActivation(
                hasLiveGatt = true,
                hasRequiredTransferCharacteristics = true,
                rememberedCameraMatches = true,
                hasCompletedCameraAck = false,
                ageMs = 30_000,
            ),
        )
    }

    @Test
    fun oldSessionCannotBeReused() {
        assertFalse(
            CameraVendorBleSessionReusePolicy.canReuseForTransferActivation(
                hasLiveGatt = true,
                hasRequiredTransferCharacteristics = true,
                rememberedCameraMatches = true,
                hasCompletedCameraAck = true,
                ageMs = CameraVendorBleSessionReusePolicy.REUSE_TTL_MS + 1,
            ),
        )
    }
}
