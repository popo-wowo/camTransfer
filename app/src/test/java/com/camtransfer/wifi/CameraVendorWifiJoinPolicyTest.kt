package com.camtransfer.wifi

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorWifiJoinPolicyTest {
    @Test
    fun autoJoinTimeoutAllowsAndroidHiddenNetworkMatchingToComplete() {
        assertEquals(30_000L, CameraVendorWifiJoinPolicy.AUTO_JOIN_TIMEOUT_MS)
    }

    @Test
    fun exactWifiRequestRetriesShortUnavailableBeforeSurfacingFailure() {
        assertEquals(3, CameraVendorWifiJoinPolicy.AUTO_JOIN_ATTEMPTS_PER_EXACT_NETWORK)
        assertEquals(1_500L, CameraVendorWifiJoinPolicy.retryDelayMs(afterFailedAttempt = 1))
        assertEquals(2_000L, CameraVendorWifiJoinPolicy.retryDelayMs(afterFailedAttempt = 2))
    }
}
