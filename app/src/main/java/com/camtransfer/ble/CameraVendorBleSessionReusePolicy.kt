package com.camtransfer.ble

object CameraVendorBleSessionReusePolicy {
    const val REUSE_TTL_MS = 2 * 60 * 1000L

    fun canReuseForTransferActivation(
        hasLiveGatt: Boolean,
        hasRequiredTransferCharacteristics: Boolean,
        rememberedCameraMatches: Boolean,
        ageMs: Long,
    ): Boolean =
        hasLiveGatt &&
            hasRequiredTransferCharacteristics &&
            rememberedCameraMatches &&
            ageMs in 0..REUSE_TTL_MS
}
