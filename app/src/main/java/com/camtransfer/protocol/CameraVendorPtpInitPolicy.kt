package com.camtransfer.protocol

data class CameraVendorPtpInitVariant(
    val label: String,
    val includeClientIpInGuid: Boolean,
)

object CameraVendorPtpInitPolicy {
    private const val LEGACY_WITH_CLIENT_IP = "CameraVendor legacy + client IP GUID"
    private const val LEGACY_WITHOUT_CLIENT_IP = "CameraVendor legacy"

    fun legacyInitVariants(): List<CameraVendorPtpInitVariant> =
        listOf(
            CameraVendorPtpInitVariant(
                label = LEGACY_WITH_CLIENT_IP,
                includeClientIpInGuid = true,
            ),
            CameraVendorPtpInitVariant(
                label = LEGACY_WITHOUT_CLIENT_IP,
                includeClientIpInGuid = false,
            ),
        )

    fun clientIpForVariant(variant: CameraVendorPtpInitVariant, socketLocalIp: String?): String? =
        socketLocalIp.takeIf { variant.includeClientIpInGuid }
}
