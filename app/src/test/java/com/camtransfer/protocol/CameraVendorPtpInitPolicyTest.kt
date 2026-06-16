package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorPtpInitPolicyTest {
    @Test
    fun legacyInitVariantsTryClientIpThenPlainLegacy() {
        val variants = CameraVendorPtpInitPolicy.legacyInitVariants()

        assertEquals(2, variants.size)
        assertEquals("CameraVendor legacy + client IP GUID", variants[0].label)
        assertEquals(true, variants[0].includeClientIpInGuid)
        assertEquals("CameraVendor legacy", variants[1].label)
        assertEquals(false, variants[1].includeClientIpInGuid)
    }

    @Test
    fun clientIpIsOnlyUsedForTheClientIpGuidVariant() {
        val variants = CameraVendorPtpInitPolicy.legacyInitVariants()

        assertEquals(
            "192.168.0.138",
            CameraVendorPtpInitPolicy.clientIpForVariant(variants[0], "192.168.0.138"),
        )
        assertEquals(
            null,
            CameraVendorPtpInitPolicy.clientIpForVariant(variants[1], "192.168.0.138"),
        )
    }
}
